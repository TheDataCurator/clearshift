"""
Generate a synthetic training history for the ClearShift lapse-risk model.

Each row is one (worker, certification) observation from the past, with the
same leading-signal features that the gold feature table
(horizontal_dev_serverless_catalog.clearshift.gold_lapse_risk_features) exposes,
plus one engineered feature (proactive_renewal_behavior) that the README flags
as a natural extension to add to the gold layer.

The label, lapsed_before_next_hazardous_job, is NOT a deterministic function of
days_to_expiry. It is drawn from a probability that depends on several leading
signals, so a model has real signal to learn and cannot just read the expiry
date. The true generating weights are documented below so we can later show the
trained model recovers the same ranking of feature importance.

TRUE GENERATING WEIGHTS (logit space), documented for defensibility:
    intercept                 b0 = -1.15
    expiry_pressure           +1.60   (rises as days_to_expiry falls / goes negative)
    prior_lapse_count         +0.55   per prior lapse
    training_backlog          +0.42   per open required training
    schedule_pressure         +0.09   per scheduled shift in the next 14 days
    proactive_renewal_behavior -1.90  (0..1; renewing early is protective)
    total_certs_held          -0.05   per cert (mildly protective: engaged workers)
    is_regulated              +0.25   (regulated work lapses matter more and are stricter)
    gaussian noise            sigma = 0.35
"""

import numpy as np
import pandas as pd

RNG = np.random.default_rng(20260924)
N = 4000

# --- draw features from plausible distributions ---------------------------
# days_to_expiry: negative = already past expiry, small positive = near expiry.
days_to_expiry = np.clip(RNG.normal(180, 210, N), -90, 900).round().astype(int)
prior_lapse_count = RNG.poisson(0.6, N)
total_certs_held = (RNG.poisson(3.0, N) + 1).astype(int)
training_backlog = RNG.poisson(1.0, N)
schedule_pressure = RNG.poisson(6.0, N)          # shifts scheduled next 14 days
is_regulated = RNG.binomial(1, 0.62, N)
proactive_renewal_behavior = RNG.beta(2.0, 2.0, N)   # 0..1, fraction renewed early

# expiry pressure: 0 when far from expiry, rising sharply as it approaches/passes
expiry_pressure = np.clip((45.0 - days_to_expiry) / 45.0, -1.0, 3.0)

# --- true logit and sampled label -----------------------------------------
logit = (
    -1.15
    + 1.60 * expiry_pressure
    + 0.55 * prior_lapse_count
    + 0.42 * training_backlog
    + 0.09 * schedule_pressure
    - 1.90 * proactive_renewal_behavior
    - 0.05 * total_certs_held
    + 0.25 * is_regulated
    + RNG.normal(0.0, 0.35, N)
)
p_lapse = 1.0 / (1.0 + np.exp(-logit))
label = RNG.binomial(1, p_lapse).astype(bool)

df = pd.DataFrame(
    {
        "employee_id": [f"E{1000 + i}" for i in range(N)],
        "qualification_id": RNG.choice(
            ["LOTO", "CONFINED", "PIT", "HOTWORK", "PSM", "RESP"], N
        ),
        "days_to_expiry": days_to_expiry,
        "prior_lapse_count": prior_lapse_count,
        "total_certs_held": total_certs_held,
        "training_backlog": training_backlog,
        "schedule_pressure": schedule_pressure,
        "is_regulated": is_regulated.astype(bool),
        "proactive_renewal_behavior": proactive_renewal_behavior.round(3),
        "lapsed_before_next_hazardous_job": label,
    }
)

if __name__ == "__main__":
    out = "model/data/lapse_history.parquet"
    df.to_parquet(out, index=False)
    rate = df["lapsed_before_next_hazardous_job"].mean()
    print(f"wrote {out}: {len(df)} rows, positive label rate {rate:.1%}")
    print(df.head(3).to_string(index=False))
