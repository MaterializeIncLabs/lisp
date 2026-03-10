import json
import pathlib

import psycopg2
import psycopg2.extras
import pytest

SQL_DIR = pathlib.Path(__file__).resolve().parent.parent


def _connect():
    conn = psycopg2.connect(
        host="localhost",
        port=6875,
        user="materialize",
        dbname="materialize",
    )
    conn.autocommit = True
    return conn


@pytest.fixture(scope="session", autouse=True)
def _setup_interpreter():
    """Ensure lisp_programs table and lisp_interpreter view exist."""
    conn = _connect()
    cur = conn.cursor()

    # Check if the table exists
    cur.execute(
        "SELECT 1 FROM mz_tables WHERE name = 'lisp_programs'"
    )
    if not cur.fetchone():
        cur.execute("CREATE TABLE lisp_programs (id INT, program JSONB)")

    # Recreate the view so it always matches the current lisp.sql
    cur.execute("DROP VIEW IF EXISTS lisp_interpreter")
    lisp_sql = (SQL_DIR / "lisp.sql").read_text()
    cur.execute(lisp_sql)

    cur.close()
    conn.close()


@pytest.fixture
def run_programs():
    conn = _connect()
    psycopg2.extras.register_default_jsonb(conn)

    def _run(programs):
        cur = conn.cursor()
        cur.execute("DELETE FROM lisp_programs")
        for db_id, expr in enumerate(programs, 1):
            cur.execute(
                "INSERT INTO lisp_programs (id, program) VALUES (%s, %s)",
                (db_id, json.dumps(expr)),
            )
        cur.execute(
            "SELECT call_stack[1] AS id, result "
            "FROM lisp_interpreter "
            "WHERE frame_pointer = 0"
        )
        results = {row[0] - 1: row[1] for row in cur.fetchall()}
        cur.close()
        return results

    yield _run

    cur = conn.cursor()
    cur.execute("DELETE FROM lisp_programs")
    cur.close()
    conn.close()
