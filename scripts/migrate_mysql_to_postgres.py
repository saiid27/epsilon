import argparse
import getpass
import os
from pathlib import Path

import mysql.connector
import psycopg2
from psycopg2.extras import execute_values


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_FILE = ROOT / "BD" / "temeyouzi.sql"

TABLES = [
    "users",
    "verification_codes",
    "courses",
    "lessons",
]

BOOLEAN_COLUMNS = {
    "users": {"phone_verified"},
    "verification_codes": {"used"},
    "courses": {"active"},
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Migrate Epsilon Education data from MySQL to PostgreSQL."
    )
    parser.add_argument("--mysql-host", default=os.getenv("MYSQLHOST", "localhost"))
    parser.add_argument("--mysql-port", type=int, default=int(os.getenv("MYSQLPORT", "3306")))
    parser.add_argument("--mysql-user", default=os.getenv("MYSQLUSER", "root"))
    parser.add_argument("--mysql-password", default=os.getenv("MYSQLPASSWORD", ""))
    parser.add_argument("--mysql-database", default=os.getenv("MYSQLDATABASE", "school_app"))

    parser.add_argument("--pg-host", default=os.getenv("PGHOST", "localhost"))
    parser.add_argument("--pg-port", type=int, default=int(os.getenv("PGPORT", "5432")))
    parser.add_argument("--pg-user", default=os.getenv("PGUSER", "postgres"))
    parser.add_argument("--pg-password", nargs="?", const="", default=os.getenv("PGPASSWORD"))
    parser.add_argument("--pg-database", default=os.getenv("PGDATABASE", "school_app"))
    parser.add_argument("--pg-url", default=os.getenv("DATABASE_URL"))

    parser.add_argument(
        "--clear",
        action="store_true",
        help="Delete PostgreSQL data from migrated tables before importing.",
    )
    return parser.parse_args()


def mysql_connect(args):
    return mysql.connector.connect(
        host=args.mysql_host,
        port=args.mysql_port,
        user=args.mysql_user,
        password=args.mysql_password,
        database=args.mysql_database,
        charset="utf8mb4",
    )


def pg_connect(args):
    if args.pg_url:
        try:
            return psycopg2.connect(args.pg_url)
        except UnicodeDecodeError as exc:
            raise SystemExit(
                "PostgreSQL connection failed. Check DATABASE_URL, username, and password."
            ) from exc
    password = args.pg_password
    if password is None:
        password = getpass.getpass(f"PostgreSQL password for {args.pg_user}: ")
    try:
        return psycopg2.connect(
            host=args.pg_host,
            port=args.pg_port,
            user=args.pg_user,
            password=password,
            dbname=args.pg_database,
        )
    except UnicodeDecodeError as exc:
        raise SystemExit(
            "PostgreSQL connection failed. Use the real postgres password, not the example text."
        ) from exc


def mysql_table_exists(conn, table):
    cur = conn.cursor()
    cur.execute("SHOW TABLES LIKE %s", (table,))
    exists = cur.fetchone() is not None
    cur.close()
    return exists


def mysql_columns(conn, table):
    cur = conn.cursor()
    cur.execute(f"SHOW COLUMNS FROM `{table}`")
    cols = [row[0] for row in cur.fetchall()]
    cur.close()
    return cols


def pg_columns(conn, table):
    cur = conn.cursor()
    cur.execute(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema='public' AND table_name=%s
        ORDER BY ordinal_position
        """,
        (table,),
    )
    cols = [row[0] for row in cur.fetchall()]
    cur.close()
    return cols


def ensure_pg_schema(conn):
    sql = SCHEMA_FILE.read_text(encoding="utf-8")
    cur = conn.cursor()
    cur.execute(sql)
    conn.commit()
    cur.close()


def clear_pg_tables(conn):
    cur = conn.cursor()
    cur.execute("TRUNCATE lessons, verification_codes, courses, users RESTART IDENTITY CASCADE")
    conn.commit()
    cur.close()


def normalize_value(table, column, value):
    if column in BOOLEAN_COLUMNS.get(table, set()) and value is not None:
        return bool(value)
    return value


def fetch_mysql_rows(conn, table, columns):
    cur = conn.cursor(dictionary=True)
    col_sql = ", ".join(f"`{col}`" for col in columns)
    cur.execute(f"SELECT {col_sql} FROM `{table}`")
    rows = []
    for row in cur.fetchall():
        rows.append(tuple(normalize_value(table, col, row.get(col)) for col in columns))
    cur.close()
    return rows


def upsert_rows(conn, table, columns, rows):
    if not rows:
        return 0

    col_sql = ", ".join(f'"{col}"' for col in columns)
    if "id" in columns:
        conflict = "id"
    elif table == "courses" and "code" in columns:
        conflict = "code"
    elif table == "users" and "username" in columns:
        conflict = "username"
    else:
        conflict = None

    if conflict:
        update_cols = [col for col in columns if col != conflict]
        update_sql = ", ".join(f'"{col}"=EXCLUDED."{col}"' for col in update_cols)
        query = f"""
            INSERT INTO {table} ({col_sql})
            VALUES %s
            ON CONFLICT ("{conflict}") DO UPDATE SET {update_sql}
        """
    else:
        query = f"INSERT INTO {table} ({col_sql}) VALUES %s"

    cur = conn.cursor()
    execute_values(cur, query, rows)
    conn.commit()
    cur.close()
    return len(rows)


def reset_sequence(conn, table):
    cur = conn.cursor()
    cur.execute("SELECT to_regclass(%s)", (f"public.{table}_id_seq",))
    if cur.fetchone()[0]:
        cur.execute(
            f"SELECT setval('{table}_id_seq', COALESCE((SELECT MAX(id) FROM {table}), 1), TRUE)"
        )
        conn.commit()
    cur.close()


def main():
    args = parse_args()
    mysql_conn = mysql_connect(args)
    pg_conn = pg_connect(args)

    try:
        ensure_pg_schema(pg_conn)
        if args.clear:
            clear_pg_tables(pg_conn)

        for table in TABLES:
            if not mysql_table_exists(mysql_conn, table):
                print(f"skip {table}: not found in MySQL")
                continue

            source_cols = mysql_columns(mysql_conn, table)
            target_cols = pg_columns(pg_conn, table)
            columns = [col for col in source_cols if col in target_cols]

            if not columns:
                print(f"skip {table}: no matching columns")
                continue

            rows = fetch_mysql_rows(mysql_conn, table, columns)
            count = upsert_rows(pg_conn, table, columns, rows)
            reset_sequence(pg_conn, table)
            print(f"migrated {table}: {count} rows")

    finally:
        mysql_conn.close()
        pg_conn.close()


if __name__ == "__main__":
    main()
