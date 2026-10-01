"""
Per-prediction explanations for the ClearShift lapse-risk model.

The model emits a probability. A score on its own does not tell a supervisor WHY
a worker is at risk or WHAT to act on. This turns the score into a plain-language
explanation grounded in that worker's own governed feature values ("expires in 12
days, 2 prior lapses, 3 overdue trainings"), using SHAP to attribute the score to
individual features for a single prediction rather than reporting one global
importance ranking that is the same for everyone.

SHAP (SHapley Additive exPlanations) gives each feature a signed contribution to
one prediction: positive raises predicted lapse risk, negative lowers it. We take
the features that moved this worker's score the most and phrase them against the
actual value, so the explanation is specific to the worker and the seat, and the
feature attribution is a property of the model, not a hand-written rule.

Used two ways:
  - model/score_batch.py calls explain_frame() to persist an explanation and the
    top signed factors alongside every (worker, qualification) score, so the app
    and the audit trail carry the reason, not just the number.
  - run directly to print example explanations on the synthetic history:
        python model/explain.py
"""

from __future__ import annotations

import json
import os

import numpy as np
import pandas as pd

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

# Score at or above which a prediction is explained by what RAISED it (its risk
# drivers) rather than what lowered it. Matches the "Elevated" label floor below,
# so a 0.46 "Elevated" case is narrated by its risk drivers (expired cert, prior
# lapse), not by its protective ones.
RISK_FLOOR = 0.33


def _phrase(feature: str, value: float):
    """Plain-language phrase for one feature at its actual value, plus the state
    that value represents: "risk" (a value that raises lapse risk), "protective"
    (lowers it), or "neutral". Phrasing is by the true value, never by the SHAP
    sign, so an explanation never describes a protective value as if it raised
    risk. Thresholds follow the documented feature semantics in
    generate_history.py (schedule_pressure is shifts in the next 14 days, mean 6;
    proactive_renewal_behavior is the 0..1 fraction renewed early)."""
    v = float(value)
    if feature == "days_to_expiry":
        if v <= 0:
            return "certification already past expiry", "risk"
        if v < 60:
            return f"certification expires in {int(round(v))} days", "risk"
        if v >= 3000:
            return "certification does not expire", "protective"
        return f"certification valid for {int(round(v))} more days", "protective"
    if feature == "prior_lapse_count":
        n = int(round(v))
        return (f"{n} prior lapse{'s' if n != 1 else ''} on record", "risk") if n > 0 \
            else ("no prior lapses", "protective")
    if feature == "training_backlog":
        n = int(round(v))
        return (f"{n} overdue training item{'s' if n != 1 else ''}", "risk") if n > 0 \
            else ("no training backlog", "protective")
    if feature == "schedule_pressure":
        if v >= 8:
            return "heavy upcoming hazardous schedule", "risk"
        if v <= 3:
            return "light upcoming schedule", "protective"
        return None, "neutral"
    if feature == "proactive_renewal_behavior":
        if v < 0.4:
            return "has not renewed ahead of expiry historically", "risk"
        if v > 0.6:
            return "renews ahead of expiry", "protective"
        return "mixed renewal history", "neutral"
    if feature == "total_certs_held":
        return None, "neutral"  # mildly protective context, not narrated alone
    if feature == "is_regulated":
        return None, "neutral"
    return None, "neutral"


def _sentence(score: float, factors: list[dict]) -> str:
    level = "High" if score >= 0.66 else "Elevated" if score >= 0.33 else "Low"
    phrases = [f["phrase"] for f in factors if f.get("phrase")]
    if not phrases:
        return f"{level} lapse risk ({score:.0%})."
    lead, rest = phrases[0], phrases[1:]
    if rest:
        return f"{level} lapse risk ({score:.0%}): {lead} is the largest factor, with {'; '.join(rest)}."
    return f"{level} lapse risk ({score:.0%}): driven by {lead}."


def build_explainer(model):
    """A SHAP TreeExplainer for a tree model, or None if SHAP or the model is
    unsupported (e.g. an opaque pyfunc). Callers fall back to a value-based
    explanation, so scoring never fails for lack of the optional dependency."""
    try:
        import shap
    except Exception:
        return None
    try:
        return shap.TreeExplainer(model)
    except Exception:
        return None


def _shap_matrix(explainer, X: pd.DataFrame):
    """A (n_rows, n_features) array of signed contributions toward the positive
    (lapse) class, normalized across the several shapes SHAP returns for a binary
    classifier (list [neg, pos], or a 3-D stack)."""
    try:
        sv = explainer.shap_values(X)
    except Exception:
        return None
    if isinstance(sv, list):
        return np.asarray(sv[-1])
    arr = np.asarray(sv)
    if arr.ndim == 3:
        return arr[:, :, -1] if arr.shape[-1] == 2 else arr[-1]
    return arr


def _fallback_factors(row: pd.Series, score: float, top_k: int) -> list[dict]:
    """Value-based factors when SHAP is unavailable: a documented ordering of the
    leading signals, phrased against actual values and filtered to the direction
    that matches the score. Keeps the feature honest even without attribution."""
    want = "risk" if float(score) >= RISK_FLOOR else "protective"
    order = ["days_to_expiry", "prior_lapse_count", "training_backlog",
             "proactive_renewal_behavior", "schedule_pressure"]
    factors = []
    for feat in order:
        phrase, state = _phrase(feat, row[feat])
        if phrase and state == want:
            factors.append({"feature": feat, "value": float(row[feat]),
                            "contribution": None, "phrase": phrase})
        if len(factors) >= top_k:
            break
    return factors


def explain_frame(model, X: pd.DataFrame, scores, top_k: int = 3) -> list[dict]:
    """Per-row explanations for a scored feature frame.

    Returns one dict per row: {score, explanation, top_factors, method}. The
    top_factors list is the signed per-feature attribution for this prediction,
    suitable to persist as JSON next to the score.
    """
    scores = np.asarray(scores, dtype=float)
    explainer = build_explainer(model)
    mat = _shap_matrix(explainer, X[FEATURES].astype(float)) if explainer is not None else None

    out = []
    for i in range(len(X)):
        row = X.iloc[i]
        score = float(scores[i])
        if mat is not None:
            contribs = mat[i]
            factors = []
            for j in np.argsort(-np.abs(contribs)):
                feat = FEATURES[j]
                contribution = float(contribs[j])
                phrase, state = _phrase(feat, row[feat])
                if phrase is None:
                    continue
                # Narrate in the direction of the prediction: a high score is
                # explained by the factors that raised it (positive SHAP on a
                # risk-state value), a low score by the factors that lowered it.
                # This keeps the sentence coherent and never claims a protective
                # value drove risk or vice versa. The signed contributions for
                # both directions remain in the SHAP matrix if ever needed.
                want_risk = score >= RISK_FLOOR
                if want_risk and not (contribution > 0 and state == "risk"):
                    continue
                if not want_risk and not (contribution < 0 and state == "protective"):
                    continue
                factors.append({"feature": feat, "value": float(row[feat]),
                                "contribution": round(contribution, 4), "phrase": phrase})
                if len(factors) >= top_k:
                    break
            method = "shap"
        else:
            factors = _fallback_factors(row, score, top_k)
            method = "value"
        out.append({"score": round(score, 4), "explanation": _sentence(score, factors),
                    "top_factors": factors, "method": method})
    return out


def _demo() -> None:
    """Print example explanations on representative cases from the synthetic
    history, so the committed evidence shows the model explaining itself."""
    from sklearn.ensemble import GradientBoostingClassifier

    hist = pd.read_parquet(HISTORY)
    X = hist[FEATURES].astype(float)
    y = hist["lapsed_before_next_hazardous_job"].astype(int)
    model = GradientBoostingClassifier(random_state=0).fit(X, y)
    proba = model.predict_proba(X)[:, 1]

    # Representative spread: two highest-risk, one mid, two lowest-risk cases.
    order = np.argsort(-proba)
    picks = list(order[:2]) + [order[len(order) // 2]] + list(order[-2:])
    Xs = X.iloc[picks].reset_index(drop=True)
    ex = explain_frame(model, Xs, proba[picks])

    print("ClearShift lapse-risk model: per-prediction explanations")
    print(f"method: SHAP TreeExplainer over {model.__class__.__name__}  "
          f"| features: {', '.join(FEATURES)}")
    print("=" * 78)
    for i, e in enumerate(ex):
        print(f"\nCase {i + 1}  (method={e['method']})")
        print(f"  explanation: {e['explanation']}")
        print(f"  score: {e['score']}")
        print("  governed feature values:")
        for f in FEATURES:
            print(f"      {f:28s} {Xs.iloc[i][f]:g}")
        print("  signed factor attribution (top drivers):")
        for f in e["top_factors"]:
            c = "n/a" if f["contribution"] is None else f"{f['contribution']:+.4f}"
            print(f"      {f['feature']:28s} value={f['value']:<10g} shap={c}  -> {f['phrase']}")
    print("\n" + "=" * 78)
    print("Persisted per (worker, qualification) in gate.lapse_risk "
          "(risk_explanation, top_factors), surfaced in the app and the audit trail.")


if __name__ == "__main__":
    _demo()
