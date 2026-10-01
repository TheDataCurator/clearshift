#!/usr/bin/env python
"""
Reseed the ClearShift demo so "tomorrow" has schedule data again, then rescore.

Why this exists: the demo is date-relative. The pre-shift clearance view and the
What-if studio read tomorrow's regulated schedule (work_date = CURRENT_DATE + 1).
The seed inserts those rows relative to the day it was first loaded, so if you
present on a later day they age out and the What-if shows "0 seats". This
repopulates tomorrow's forward schedule (and yesterday's unplanned transfer) and
re-runs the lapse-risk scoring, so the whole demo is live for the current date.

Run it from the repo root the morning you present.

Against the deployed Lakebase (the app's database), using a Databricks CLI
profile that can reach the ClearShift workspace:

    python scripts/reseed.py --profile horizontals

Against a local Postgres named `clearshift` (the local dev setup in the README):

    LAKEBASE_HOST=localhost PGPASSWORD=<your-pw> python scripts/reseed.py --local

It does two things:
    1. refreshes tomorrow's forward schedule + yesterday's transfer from
       lakebase/ddl/02_seed.sql (idempotent: it clears those date-relative rows
       first, so it is safe to run every day), and
    2. re-runs model/score_batch.py to repopulate gate.lapse_risk with fresh
       scores and SHAP explanations.

Requires: psycopg2 and (for the non-local path) databricks-sdk, both already in
the model virtualenv (.venv-model).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SEED = os.path.join(ROOT, "lakebase", "ddl", "02_seed.sql")

# Defaults mirror app/app.yaml so the deployed database works with no extra flags.
HOST = os.getenv("LAKEBASE_HOST", "ep-noisy-dew-d2l32b6o.database.us-east-1.cloud.databricks.com")
PORT = os.getenv("LAKEBASE_PORT", "5432")
DB = os.getenv("LAKEBASE_DATABASE", "clearshift")
ENDPOINT = os.getenv("LAKEBASE_ENDPOINT", "projects/clearshift/branches/production/endpoints/primary")


def _statement_after(sql: str, marker: str) -> str:
    """Return the single INSERT statement that follows a comment marker in the
    seed file, so we run the real seed SQL rather than a transcription of it."""
    i = sql.index(marker)
    j = sql.index("INSERT INTO", i)
    k = sql.index(";", j)
    return sql[j:k + 1]


def main() -> None:
    ap = argparse.ArgumentParser(description="Reseed tomorrow's schedule and rescore the demo.")
    ap.add_argument("--profile", default=os.getenv("DATABRICKS_CONFIG_PROFILE", "horizontals"),
                    help="Databricks CLI profile for the Lakebase workspace (default: horizontals)")
    ap.add_argument("--local", action="store_true",
                    help="target a local Postgres with PGPASSWORD instead of a Lakebase OAuth token")
    args = ap.parse_args()

    if args.local:
        host = os.getenv("LAKEBASE_HOST", "localhost")
        user = os.getenv("LAKEBASE_USER", os.getenv("USER", "postgres"))
        password = os.getenv("PGPASSWORD", "")
        sslmode = os.getenv("PGSSLMODE", "prefer")
    else:
        os.environ["DATABRICKS_CONFIG_PROFILE"] = args.profile
        from databricks.sdk import WorkspaceClient

        w = WorkspaceClient()
        host = HOST
        user = w.current_user.me().user_name
        password = w.api_client.do(
            "POST", "/api/2.0/postgres/credentials", body={"endpoint": ENDPOINT}
        )["token"]
        sslmode = "require"

    import psycopg2

    sql = open(SEED).read()
    forward = _statement_after(sql, "-- Forward schedule: tomorrow")
    transfer = _statement_after(sql, "-- Yesterday: an unplanned mid-shift transfer")

    conn = psycopg2.connect(host=host, port=PORT, dbname=DB, user=user,
                            password=password, sslmode=sslmode)
    with conn, conn.cursor() as cur:
        # Idempotent: clear the date-relative rows we are about to re-insert.
        cur.execute("DELETE FROM gate.employee_scheduled_workcenter_history "
                    "WHERE work_date >= CURRENT_DATE + 1")
        cur.execute(forward)
        cur.execute("DELETE FROM gate.employee_scheduled_workcenter_history "
                    "WHERE work_date = CURRENT_DATE - 1 AND has_transfer_on_date")
        cur.execute(transfer)
        cur.execute("SELECT count(DISTINCT employee_id || '|' || work_center_id) "
                    "FROM gate.v_shift_clearance "
                    "WHERE work_date = CURRENT_DATE + 1 AND is_regulated")
        seats = cur.fetchone()[0]
    conn.close()
    print(f"reseeded: {seats} regulated seats scheduled for tomorrow")

    # Rescore so the worker pool carries fresh lapse risk and explanations.
    env = dict(os.environ, LAKEBASE_HOST=host, LAKEBASE_PORT=str(PORT),
               LAKEBASE_DATABASE=DB, LAKEBASE_USER=user, PGPASSWORD=password,
               PGSSLMODE=sslmode)
    subprocess.run([sys.executable, os.path.join(ROOT, "model", "score_batch.py")],
                   check=True, env=env)


if __name__ == "__main__":
    main()
