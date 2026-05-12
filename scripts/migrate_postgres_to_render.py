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
    "free_pdfs",
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


def fetch_dict_rows(conn, table, cols):
    col_sql = ", ".join(f'"{col}"' for col in cols)
    order_sql = " ORDER BY id ASC" if "id" in cols else ""
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute(f"SELECT {col_sql} FROM {table}{order_sql}")
    rows = cur.fetchall()
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


def get_target_user_id(conn, username, phone):
    cur = conn.cursor()
    cur.execute(
        "SELECT id FROM users WHERE username=%s OR phone=%s ORDER BY id ASC LIMIT 1",
        (username, phone),
    )
    row = cur.fetchone()
    cur.close()
    return row[0] if row else None


def insert_user_if_missing(conn, row, cols):
    existing_id = get_target_user_id(conn, row.get("username"), row.get("phone"))
    if existing_id:
        return existing_id, False

    insert_cols = [col for col in cols if col != "id"]
    col_sql = ", ".join(f'"{col}"' for col in insert_cols)
    placeholders = ", ".join(["%s"] * len(insert_cols))
    values = [row[col] for col in insert_cols]
    cur = conn.cursor()
    cur.execute(
        f"INSERT INTO users ({col_sql}) VALUES ({placeholders}) RETURNING id",
        values,
    )
    new_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    return new_id, True


def insert_if_missing(conn, table, row, cols, conflict_cols):
    insert_cols = [col for col in cols if col != "id"]
    col_sql = ", ".join(f'"{col}"' for col in insert_cols)
    placeholders = ", ".join(["%s"] * len(insert_cols))
    conflict_sql = ", ".join(f'"{col}"' for col in conflict_cols)
    values = [row[col] for col in insert_cols]
    cur = conn.cursor()
    cur.execute(
        f"""
        INSERT INTO {table} ({col_sql})
        VALUES ({placeholders})
        ON CONFLICT ({conflict_sql}) DO NOTHING
        """,
        values,
    )
    inserted = cur.rowcount
    conn.commit()
    cur.close()
    return inserted


def insert_free_pdf_if_missing(conn, row, cols):
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id
        FROM free_pdfs
        WHERE course_code=%s AND subject=%s AND title=%s AND drive_url=%s
        LIMIT 1
        """,
        (row.get("course_code"), row.get("subject"), row.get("title"), row.get("drive_url")),
    )
    if cur.fetchone():
        cur.close()
        return 0

    insert_cols = [col for col in cols if col != "id"]
    col_sql = ", ".join(f'"{col}"' for col in insert_cols)
    placeholders = ", ".join(["%s"] * len(insert_cols))
    cur.execute(
        f"INSERT INTO free_pdfs ({col_sql}) VALUES ({placeholders})",
        [row[col] for col in insert_cols],
    )
    conn.commit()
    cur.close()
    return 1


def append_only_copy(source, target):
    user_id_map = {}

    for table in TABLES:
        if not table_exists(source, table):
            print(f"skip {table}: not found locally")
            continue
        if not table_exists(target, table):
            print(f"skip {table}: not found on target")
            continue

        source_cols = columns(source, table)
        target_cols = columns(target, table)
        cols = [col for col in source_cols if col in target_cols]
        rows = fetch_dict_rows(source, table, cols)
        inserted = 0

        if table == "users":
            for row in rows:
                target_id, was_inserted = insert_user_if_missing(target, row, cols)
                if row.get("id") is not None:
                    user_id_map[row["id"]] = target_id
                inserted += int(was_inserted)
        elif table == "courses":
            for row in rows:
                inserted += insert_if_missing(target, table, row, cols, ["code"])
        elif table == "course_subjects":
            for row in rows:
                inserted += insert_if_missing(target, table, row, cols, ["course_code", "subject"])
        elif table == "lessons":
            for row in rows:
                if row.get("uploaded_by") in user_id_map:
                    row["uploaded_by"] = user_id_map[row["uploaded_by"]]
                insert_cols = [col for col in cols if col != "id"]
                col_sql = ", ".join(f'"{col}"' for col in insert_cols)
                placeholders = ", ".join(["%s"] * len(insert_cols))
                cur = target.cursor()
                cur.execute(
                    f"INSERT INTO lessons ({col_sql}) VALUES ({placeholders})",
                    [row[col] for col in insert_cols],
                )
                target.commit()
                cur.close()
                inserted += 1
        elif table == "free_pdfs":
            for row in rows:
                inserted += insert_free_pdf_if_missing(target, row, cols)
        elif table == "verification_codes":
            for row in rows:
                insert_cols = [col for col in cols if col != "id"]
                col_sql = ", ".join(f'"{col}"' for col in insert_cols)
                placeholders = ", ".join(["%s"] * len(insert_cols))
                cur = target.cursor()
                cur.execute(
                    f"INSERT INTO verification_codes ({col_sql}) VALUES ({placeholders})",
                    [row[col] for col in insert_cols],
                )
                target.commit()
                cur.close()
                inserted += 1

        reset_sequence(target, table)
        print(f"added {table}: {inserted} rows")


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
        else:
            append_only_copy(source, target)
    finally:
        source.close()
        target.close()


if __name__ == "__main__":
    main()
