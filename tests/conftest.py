import json

import psycopg2
import psycopg2.extras
import pytest


@pytest.fixture
def run_programs():
    conn = psycopg2.connect(
        host="localhost",
        port=6875,
        user="materialize",
        dbname="materialize",
    )
    conn.autocommit = True
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
