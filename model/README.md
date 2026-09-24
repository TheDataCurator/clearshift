# ClearShift lapse-risk model and crew optimizer

This directory holds the AI decisioning layer for ClearShift. It has two parts:
a trained model that predicts certification lapse risk, and a constraint
optimizer that turns those predictions into a compliant crew plan. They are
separate on purpose: the model is machine learning, the optimizer is operations
research, and each does what it is good at.

## 1. Lapse-risk model (`train.py`, `generate_history.py`)

**What it predicts.** For each (worker, certification), the probability that the
certification lapses before the worker's next scheduled hazardous job. This is a
forecast, not a date lookup. It lets ClearShift act before a worker falls out of
compliance rather than after.

**Why this is real machine learning, not arithmetic.** A pure rule
(`expires_on < shift_date`) only tells you who is already expired. The model
predicts who is likely to lapse, using leading behavioral signals:

- `days_to_expiry`: how close the certification is to expiring (or past it).
- `proactive_renewal_behavior`: whether the worker historically renews early.
- `training_backlog`: open required training that gates renewal.
- `prior_lapse_count`: history of previous lapses.
- `schedule_pressure`: how heavily the worker is booked in the near term.
- `total_certs_held`, `is_regulated`: context.

These come from `gold_lapse_risk_features` in the pipeline.
`proactive_renewal_behavior` is the one engineered feature not yet materialized
in gold; it is a natural next addition (fraction of a worker's past
certifications renewed before expiry).

**Training data.** The live demo carries only a handful of workers, so
`generate_history.py` produces a synthetic history of 4,000 (worker,
certification) observations. The label is drawn probabilistically from the
features (a sigmoid of a documented weighted sum plus noise), so the model has
genuine signal to learn and cannot simply read the expiry date. The true
generating weights are written in that file so we can confirm the model recovers
the same ranking.

**Model.** A gradient-boosted classifier (xgboost or lightgbm if installed, else
scikit-learn `GradientBoostingClassifier`). Boosted trees handle the nonlinear,
interacting signals here and give clear feature importances to explain a score.

**Measured performance (local run).** ROC AUC 0.878, precision 0.875, recall
0.722, F1 0.791. Feature importance ranks `days_to_expiry` first, then
`proactive_renewal_behavior`, `training_backlog`, and `prior_lapse_count`, which
matches how the data was generated. Expiry proximity carries most of the signal,
as expected, and the behavioral features add the lift that lets the model warn
early rather than just report expiries.

**MLflow.** Everything logs to MLflow (params, metrics, a feature-importance
plot, and the model with a signature and input example). Default runs use a
local MLflow store and never touch the workspace. Passing `--register` sets
tracking to Databricks and the registry to Unity Catalog and registers the model
as `horizontal_dev_serverless_catalog.clearshift.lapse_risk_model`, ready to put
behind a serving endpoint.

## 2. Crew optimizer (`optimizer.py`)

**What it does.** Given the scheduled hazardous jobs, the worker pool with their
current in-scope qualifications, and the lapse-risk scores from the model, it
produces a compliant crew assignment.

**Hard constraints (never violated):**

- a worker is only assigned to a job whose required qualification they currently
  hold, in scope for that plant;
- a first performance of a regulated task is paired with a qualified supervisor
  at that plant;
- no worker is double-booked.

**Objective.** Cover as many scheduled jobs as possible, then, among feasible
assignments, prefer lower-risk workers so scarce low-risk capacity is spent where
it matters. Jobs that cannot be compliantly staffed are reported explicitly
rather than silently left unfilled.

**Why CP-SAT.** Compliant crew assignment is a constraint-satisfaction problem
with a cost objective. Google OR-Tools CP-SAT expresses the hard rules exactly
and guarantees a feasible, optimal-within-model plan, which a heuristic cannot.

**Demo result.** On the sample scenario it assigns the low-risk worker to the
lockout/tagout job over the high-risk one, staffs the confined-space job with a
supervisor present, and flags the hot-work job at a plant with no eligible worker
as uncovered.

## How the two connect

Predict risk, then decide. The model scores every worker-certification pair; the
optimizer consumes those scores to build the plan behind the What-if studio.
Together they answer the business question ("can we field a compliant crew
tomorrow, and where are we exposed?") and the technical question ("who is likely
to lapse, and why?").

## Running locally

```
python model/generate_history.py          # writes model/data/lapse_history.parquet
python model/train.py                      # local MLflow, prints metrics
python model/optimizer.py                  # solves the sample scenario
python model/train.py --register --profile horizontals   # registers to UC (touches workspace)
```
