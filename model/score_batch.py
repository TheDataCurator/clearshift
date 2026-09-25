"""
Batch-score lapse risk and persist it to Lakebase.

This is the offline half of the AI decisioning layer. It reads the leading-signal
features from gate.v_lapse_risk_features, scores every (worker, qualification)
with the lapse-risk model, and writes the probabilities to gate.lapse_risk. The
What-if studio then reads those scores and runs the CP-SAT optimizer live. A
solver must not call a serving endpoint in a loop, and constraints change
intraday, so scoring is a batch job and optimization is the online step.

Model source, in order of preference:
    --model-uri <uri>   load a specific model (e.g. a UC/registered model
                        models:/horizontal_dev_serverless_catalog.clearshift.lapse_risk_model/1,
                        which is what serves in production)
    (default)           reproduce the model locally from the documented synthetic
                        history (model/data/lapse_history.parquet), so the full
                        chain runs offline without workspace access. Same model
                        class and same training data as model/train.py.

Database connection comes from the LAKEBASE_* / PG* environment, defaulting to a
local Postgres named clearshift, so the same script runs locally and in a job.

Usage:
    python model/score_batch.py
    python model/score_batch.py --model-uri models:/....clearshift.lapse_risk_model/1
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

import numpy as np
import pandas as pd
import psycopg2
import psycopg2.extras

FEATURES = [
    "days_to_expiry",
    "prior_lapse_count",
    "total_certs_held",
    "training_backlog",
    "schedule_pressure",
    "is_regulated",
    "proactive_renewal_behavior",
]

HISTORY = os.path.join(os.path.dirname(__file__), "data", "lapse_history.parquet")


def _connect():
    return psycopg2.connect(
        host=os.getenv("LAKEBASE_HOST", "localhost"),
        port=int(os.getenv("LAKEBASE_PORT", "5432")),
        dbname=os.getenv("LAKEBASE_DATABASE", "clearshift"),
        user=os.getenv("LAKEBASE_USER", os.getenv("USER", "postgres")),
        password=os.getenv("PGPASSWORD", ""),
    )


def _load_registered(model_uri: str):
    import mlflow

    print(f"loading model from {model_uri}")
    return mlflow.pyfunc.load_model(model_uri), model_uri


def _train_local():
    """Reproduce the lapse-risk model from the documented synthetic history.

    Same estimator and data as model/train.py, so a local score matches what the
    registered model learned. Deterministic: the history seed is fixed.
    """
    if not os.path.exists(HISTORY):
        print("synthetic history missing; generating it")
        subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "generate_history.py")],
                       check=True)
    from sklearn.ensemble import GradientBoostingClassifier

    hist = pd.read_parquet(HISTORY)
    X = hist[FEATURES].astype(float)
    y = hist["lapsed_before_next_hazardous_job"].astype(int)
    model = GradientBoostingClassifier(random_state=0)
    model.fit(X, y)
    ver = f"local-gbc-sklearn:{len(hist)}rows"
    print(f"trained local model on {len(hist)} synthetic observations ({ver})")
    return model, ver


def _predict(model, X: pd.DataFrame) -> np.ndarray:
    """Probability of lapse. Works for a sklearn estimator or an mlflow pyfunc."""
    if hasattr(model, "predict_proba"):
        return model.predict_proba(X)[:, 1]
    out = np.asarray(model.predict(X))
    # A pyfunc classifier may already return the positive-class probability.
    return out if out.ndim == 1 else out[:, -1]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-uri", default=None,
                    help="MLflow/UC model URI. Omit to reproduce the model locally.")
    args = ap.parse_args()

    model, version = (_load_registered(args.model_uri) if args.model_uri else _train_local())

    conn = _connect()
    feats = pd.read_sql(
        "SELECT employee_id, qualification_id, " + ", ".join(FEATURES)
        + " FROM gate.v_lapse_risk_features",
        conn,
    )
    if feats.empty:
        print("no features to score; is the database seeded?")
        return

    X = feats[FEATURES].copy()
    X["is_regulated"] = X["is_regulated"].astype(int)
    feats["lapse_risk"] = np.round(_predict(model, X.astype(float)), 4)

    rows = list(feats[["employee_id", "qualification_id", "lapse_risk"]].itertuples(index=False, name=None))
    with conn, conn.cursor() as cur:
        psycopg2.extras.execute_values(
            cur,
            """
            INSERT INTO gate.lapse_risk (employee_id, qualification_id, lapse_risk, model_version, scored_on)
            VALUES %s
            ON CONFLICT (employee_id, qualification_id)
            DO UPDATE SET lapse_risk = EXCLUDED.lapse_risk,
                          model_version = EXCLUDED.model_version,
                          scored_on = EXCLUDED.scored_on
            """,
            [(e, q, float(r), version) for (e, q, r) in rows],
            template="(%s, %s, %s, %s, current_date)",
        )
    conn.close()

    # Committed evidence: the highest-risk certifications, in text.
    top = feats.sort_values("lapse_risk", ascending=False).head(12)
    print(f"\nscored {len(feats)} (worker, qualification) pairs; model_version={version}")
    print("highest lapse risk:")
    print(top[["employee_id", "qualification_id", "days_to_expiry",
               "prior_lapse_count", "training_backlog", "lapse_risk"]]
          .to_string(index=False))
    print(f"\nmean predicted lapse risk: {feats['lapse_risk'].mean():.3f}")


if __name__ == "__main__":
    main()
