"""
Train the ClearShift lapse-risk model.

Predicts P(a worker's certification lapses before their next scheduled hazardous
job) from the leading-signal features in the gold feature table. Uses a
gradient-boosted classifier (xgboost or lightgbm if available, else sklearn
GradientBoostingClassifier).

Modes:
    default        local MLflow file store, no workspace contact (for validation)
    --register     set MLflow tracking to Databricks + UC registry and register
                   as horizontal_dev_serverless_catalog.clearshift.lapse_risk_model
                   (does nothing unless the flag is passed)

Usage:
    python model/train.py
    python model/train.py --register --profile horizontals
"""

import argparse
import os
import tempfile

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import mlflow
from mlflow.models.signature import infer_signature
from sklearn.model_selection import train_test_split
from sklearn.metrics import (
    roc_auc_score,
    precision_recall_fscore_support,
    confusion_matrix,
)

FEATURES = [
    "days_to_expiry",
    "prior_lapse_count",
    "total_certs_held",
    "training_backlog",
    "schedule_pressure",
    "is_regulated",
    "proactive_renewal_behavior",
]
TARGET = "lapsed_before_next_hazardous_job"
UC_MODEL = "horizontal_dev_serverless_catalog.clearshift.lapse_risk_model"


def build_model():
    """Prefer a boosted-tree library; fall back gracefully."""
    try:
        from xgboost import XGBClassifier

        return "xgboost", XGBClassifier(
            n_estimators=300, max_depth=4, learning_rate=0.08,
            subsample=0.9, colsample_bytree=0.9, eval_metric="logloss",
        )
    except Exception:
        pass
    try:
        from lightgbm import LGBMClassifier

        return "lightgbm", LGBMClassifier(
            n_estimators=400, max_depth=5, learning_rate=0.05
        )
    except Exception:
        pass
    from sklearn.ensemble import GradientBoostingClassifier

    return "sklearn_gbm", GradientBoostingClassifier(
        n_estimators=300, max_depth=3, learning_rate=0.08
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--register", action="store_true",
                    help="register to Databricks UC (contacts the workspace)")
    ap.add_argument("--profile", default="horizontals")
    ap.add_argument("--data", default="model/data/lapse_history.parquet")
    args = ap.parse_args()

    df = pd.read_parquet(args.data)
    X = df[FEATURES].astype(float)
    y = df[TARGET].astype(int)
    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=0.25, random_state=7, stratify=y
    )

    flavor, model = build_model()
    model.fit(X_tr, y_tr)

    proba = model.predict_proba(X_te)[:, 1]
    pred = (proba >= 0.5).astype(int)
    auc = roc_auc_score(y_te, proba)
    prec, rec, f1, _ = precision_recall_fscore_support(
        y_te, pred, average="binary", zero_division=0
    )
    cm = confusion_matrix(y_te, pred)
    importances = dict(
        sorted(
            zip(FEATURES, np.asarray(model.feature_importances_, dtype=float)),
            key=lambda kv: kv[1], reverse=True,
        )
    )

    print(f"model flavor: {flavor}")
    print(f"ROC AUC: {auc:.3f}   precision: {prec:.3f}   recall: {rec:.3f}   F1: {f1:.3f}")
    print(f"confusion matrix [[tn fp][fn tp]]: {cm.tolist()}")
    print("feature importances (desc):")
    for k, v in importances.items():
        print(f"    {k:28s} {v:.3f}")

    # --- MLflow ---
    if args.register:
        os.environ["DATABRICKS_CONFIG_PROFILE"] = args.profile
        mlflow.set_tracking_uri("databricks")
        mlflow.set_registry_uri("databricks-uc")
        mlflow.set_experiment("/Users/hayley.horn@databricks.com/clearshift_lapse_risk")
    else:
        # local validation: recent MLflow guards the plain file store, so opt in
        os.environ.setdefault("MLFLOW_ALLOW_FILE_STORE", "true")
        mlflow.set_tracking_uri(f"file://{os.path.abspath('model/mlruns')}")
        mlflow.set_experiment("clearshift_lapse_risk_local")

    signature = infer_signature(X_te, proba)
    input_example = X_te.head(3)

    with mlflow.start_run(run_name=f"lapse_risk_{flavor}"):
        mlflow.log_params({"flavor": flavor, "n_features": len(FEATURES),
                           "n_train": len(X_tr), "n_test": len(X_te)})
        mlflow.log_metrics({"roc_auc": auc, "precision": prec,
                            "recall": rec, "f1": f1})
        for k, v in importances.items():
            mlflow.log_metric(f"importance_{k}", v)

        fig, ax = plt.subplots(figsize=(6, 3.5))
        ax.barh(list(importances)[::-1], list(importances.values())[::-1])
        ax.set_title("Lapse-risk feature importance")
        fig.tight_layout()
        with tempfile.TemporaryDirectory() as d:
            fp = os.path.join(d, "feature_importance.png")
            fig.savefig(fp, dpi=120)
            mlflow.log_artifact(fp)
        plt.close(fig)

        kwargs = dict(name="model", signature=signature, input_example=input_example,
                      serialization_format="cloudpickle")
        if args.register:
            kwargs["registered_model_name"] = UC_MODEL
        mlflow.sklearn.log_model(model, **kwargs)

    if args.register:
        print(f"registered to UC as {UC_MODEL}")
    else:
        print("logged to local MLflow (model/mlruns); no workspace contact")


if __name__ == "__main__":
    main()
