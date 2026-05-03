import argparse
import getpass
import os
from pathlib import Path

import psycopg2
from psycopg2.extras import RealDictCursor, execute_values


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_FILE = ROOT / "BD" / "temeyouzi.sql"

TABLES = [
    "users",
    "courses",
    "course_subjects",
    "verification_codes",
    "lessons",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Copy local PostgreSQL data to Render PostgreSQL."
    )
    parser.add_argument("--source-host", default=os.getenv("PGHOST", "localhost"))
    parser.add_argument("--source-port", type=int, default=int(os.getenv("PGPORT", "5432")))
    parser.add_argument("--source-user", default=os.getenv("PGUSER", "postgres"))
    parser.add_argument("--source-password", default=os.getenv("PGPASSWORD"))
    parser.add_argument("--source-database", default=os.getenv("PGDATABASE", "school_app"))
    parser.add_argument(
        "--target-url",
        default=os.getenv("RENDER_DATABASE_URL") or os.getenv("TARGET_DATABASE_URL"),
        help="Render External Database URL.",
    )
    parser.add_argument(
        "--clear",
        action="store_true",
        help="Delete Render data from copied tables before importing.",
    )
    return parser.parse_args()


def connect_source(args):
    password = args.source_password
    if password is None:
        password = getpass.getpass(f"Local PostgreSQL password for {args.source_user}: ")
    return psycopg2.connect(
        host=args.source_host,
        port=args.source_port,
        user=args.source_user,
        password=password,
        dbname=args.source_database,
    )


def connect_target(args):
    if not args.target_url:
        raise SystemExit("Missing --target-url. Use Render's External Database URL.")
    return psycopg2.connect(args.target_url)


def ensure_schema(conn):
    sql = SCHEMA_FILE.read_text(encoding="utf-8")
    cur = conn.cursor()
    cur.execute(sql)
    conn.commit()
    cur.close()


def table_exists(conn, table):
    cur = conn.cursor()
    cur.execute("SELECT to_regclass(%s)", (f"public.{table}",))
    exists = cur.fetchone()[0] is not None
    cur.close()
    return exists


def columns(conn, table):
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
    result = [row[0] for row in cur.fetchall()]
    cur.close()
    return result


def fetch_rows(conn, table, cols):
    col_sql = ", ".join(f'"{col}"' for col in cols)
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute(f"SELECT {col_sql} FROM {table} ORDER BY id ASC")
    rows = [tuple(row[col] for col in cols) for row in cur.fetchall()]
    cur.close()
    return rows


def clear_target(conn):
    cur = conn.cursor()
    cur.execute(
        "TRUNCATE lessons, verification_codes, course_subjects, courses, users RESTART IDENTITY CASCADE"
    )
    conn.commit()
    cur.close()


def upsert_rows(conn, table, cols, rows):
    if not rows:
        return 0

    col_sql = ", ".join(f'"{col}"' for col in cols)
    if "id" in cols:
        conflict = "id"
    elif table == "courses":
        conflict = "code"
    elif table == "course_subjects":
        conflict = None
    elif table == "users":
        conflict = "username"
    else:
        conflict = None

    if conflict:
        update_cols = [col for col in cols if col != conflict]
        update_sql = ", ".join(f'"{col}"=EXCLUDED."{col}"' for col in update_cols)
        query = f"""
            INSERT INTO {table} ({col_sql})
            VALUES %s
            ON CONFLICT ("{conflict}") DO UPDATE SET {update_sql}
        """
    else:
        query = f"INSERT INTO {table} ({col_sql}) VALUES %s ON CONFLICT DO NOTHING"

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
    source = connect_source(args)
    target = connect_target(args)

    try:
        ensure_schema(target)
        if args.clear:
            clear_target(target)

        for table in TABLES:
            if not table_exists(source, table):
                print(f"skip {table}: not found locally")
                continue

            source_cols = columns(source, table)
            target_cols = columns(target, table)
            cols = [col for col in source_cols if col in target_cols]
            if not cols:
                print(f"skip {table}: no matching columns")
                continue

            rows = fetch_rows(source, table, cols)
            count = upsert_rows(target, table, cols, rows)
            reset_sequence(target, table)
            print(f"copied {table}: {count} rows")
    finally:
        source.close()
        target.close()


if __name__ == "__main__":
    main()
