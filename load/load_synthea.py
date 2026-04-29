"""
Loads Synthea CSV exports into synthea_raw schema in PostgreSQL.
Uses psycopg2 COPY FROM STDIN — streams CSVs directly into Postgres
without loading them into Python memory first.
Idempotent: drops and recreates each table on every run.
"""

import os
import glob
import psycopg2
from dotenv import load_dotenv

DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")
ENV_FILE = os.path.join(os.path.dirname(__file__), "..", ".env")
SCHEMA = "synthea_raw"


def get_connection():
    load_dotenv(ENV_FILE)
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
    )


def derive_columns(csv_path):
    """Read header row and return list of lowercase column names."""
    with open(csv_path, "r") as f:
        header = f.readline().strip()
    return [col.strip().lower() for col in header.split(",")]


def load_csv(cur, table, csv_path, columns):
    col_list = ", ".join(f'"{c}"' for c in columns)
    col_defs = ", ".join(f'"{c}" TEXT' for c in columns)

    cur.execute(f'DROP TABLE IF EXISTS {SCHEMA}."{table}"')
    cur.execute(f'CREATE TABLE {SCHEMA}."{table}" ({col_defs})')

    with open(csv_path, "r") as f:
        f.readline()  # skip header — COPY expects data rows only
        cur.copy_expert(
            f'COPY {SCHEMA}."{table}" ({col_list}) FROM STDIN WITH (FORMAT CSV)',
            f,
        )


def main():
    csv_files = sorted(glob.glob(os.path.join(DATA_DIR, "*.csv")))
    if not csv_files:
        print(f"No CSV files found in {DATA_DIR}")
        return

    conn = get_connection()
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            cur.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")

            for csv_path in csv_files:
                table = os.path.splitext(os.path.basename(csv_path))[0]
                columns = derive_columns(csv_path)
                load_csv(cur, table, csv_path, columns)

                cur.execute(f'SELECT COUNT(*) FROM {SCHEMA}."{table}"')
                count = cur.fetchone()[0]
                print(f"  {table:<25} {count:>8,} rows")

        conn.commit()
        print("\nAll tables loaded successfully.")

    except Exception as e:
        conn.rollback()
        print(f"\nERROR: {e}")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
