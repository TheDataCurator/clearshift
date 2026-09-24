# ClearShift medallion pipeline

This is the data journey behind ClearShift: raw operational extracts land, get
cleaned and quality-checked, and resolve into the governed tables the app,
Genie, and the lapse-risk model all read. It is a Lakeflow Declarative Pipeline
(`pipeline/clearshift_pipeline.py`) plus a small synthetic data generator
(`generate_raw.py`). Everything runs on synthetic data for fictional Meridian
Manufacturing. No real customer data is involved.

## The three layers

**Bronze** ingests each raw source folder with Auto Loader as a streaming table,
exactly as landed, with an ingest timestamp and source-file column added. The
sources mirror what a manufacturer already has: workforce from HCM, schedule and
work-center history from the time system, certifications held, work-center and
job requirements, the supervised-first-performance ledger, training, and
recordable incidents.

**Silver** types every column, deduplicates on the natural key, and applies data
quality expectations (`@dlt.expect`): valid date windows on certifications,
non-null identifiers, and an active-paystatus check on the workforce. Bad rows
are dropped or flagged rather than silently carried forward.

**Gold** is the ClearShift logic. Each gold table reimplements a specific view
from the original design and is the contract the rest of the product reads:

- `gold_qualification_state`: for each person and certification, the state as of
  today. CURRENT, EXPIRING (inside the renewal warning window), EXPIRED, REVOKED,
  or OUT_OF_SCOPE (a site-specific authorization held for a different plant).
- `gold_requirement_for_shift`: what each scheduled shift demands, combining the
  work-center requirement and the job requirement into one row per qualification.
- `gold_shift_clearance`: the closed loop. Every scheduled requirement resolves
  to a verdict with a plain-language reason. Verdicts: CLEARED, CLEARED_EXPIRING,
  SUPERVISION_REQUIRED, NOT_CLEARED.
- `gold_site_coverage`: per-plant rollup of scheduled versus cleared workers and
  a coverage percentage. This is the executive and coverage-planning view.
- `gold_first_time_hazardous`: scheduled work that is a genuine first performance
  of a regulated activity, which is the highest-risk moment and needs supervision.
- `gold_renewal_pipeline`: what lapses and when, bucketed LAPSED / DUE_30 / DUE_60
  / DUE_90, for the training coordinator.
- `gold_audit_record`: the audit answer. Every scheduled requirement, its verdict,
  and the evidence reference behind it, stamped with an as-of date.
- `gold_lapse_risk_features`: one row per (worker, certification) with the leading
  signals for the lapse-risk model (days to expiry, prior lapse count, training
  backlog, schedule pressure, certifications held) and a label placeholder.

## How clearance is decided

A worker is cleared for a scheduled shift when, for every qualification that the
work center or the job requires, the worker holds that qualification and it is
current and in scope. The logic resolves ambiguity toward flagging: a missing
requirement record or an unreadable scope produces NOT_CLEARED rather than
silence. Two notions of "first time" are kept separate on purpose. First time at
a work center is context. First time performing a regulated activity anywhere is
the safety trigger, and when the qualification requires a supervised first
performance and that record is still open, the verdict is SUPERVISION_REQUIRED
rather than CLEARED. Experience only counts from days the worker actually held
the qualification, so work performed while unqualified is treated as an exposure,
not as training.

## Running it

1. Generate the raw files locally: `python3 pipeline/generate_raw.py`. This writes
   one folder per source under `pipeline/raw/`.
2. Upload those folders to the volume named in `clearshift.raw_path` (default
   `/Volumes/clearshift/raw/landing`).
3. Set the workspace host in `databricks.yml`, then `databricks bundle deploy -t dev`
   and `databricks bundle run clearshift_pipeline -t dev`.

The bronze/silver/gold tables land in the `clearshift` catalog. Genie (Session 2)
sits on the gold tables, and the lapse-risk model (Session 3) trains on
`gold_lapse_risk_features`.

## Assumptions and gaps

- The gold tables reproduce the semantics of the Postgres views in
  `lakebase/ddl/03_views.sql`, `05_compliance.sql`, and `06_audit.sql`, adapted to
  Spark SQL (interval math becomes `date_add`/`datediff`, `string_agg` becomes
  `concat_ws` over a sorted set). The clearance and first-performance rules are a
  faithful port.
- `gold_lapse_risk_features` leaves the label null on purpose. Building the
  historical label (did this certification lapse before the worker's next
  scheduled hazardous job) is part of model development in Session 3.
- Coverage counts a worker as cleared for the site if none of their scheduled
  requirements are blocked; a per-requirement view is available in
  `gold_shift_clearance` for drill-down.
