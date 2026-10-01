# ClearShift: proving no one performs regulated work without proven qualification

## The business outcome

Manufacturers with hazardous work (confined space entry, hot work, lockout/tagout,
powered industrial trucks) carry a daily exposure their learning management system
cannot see: a person can be scheduled tomorrow into work they are not currently
qualified to perform. The LMS records who took a course. It does not answer the
operational question a plant manager actually has at 5 p.m.: is tomorrow's shift
compliantly staffed, and if not, who do I move.

ClearShift answers three questions the LMS cannot:

1. Is this person cleared for the work they are scheduled to do tomorrow?
2. Is every regulated requirement at this site currently held, and can we prove it
   the day an auditor asks?
3. When a seat will not clear, who is the compliant, lowest-risk substitute, and
   which seats cannot be staffed at all so we act before the shift?

**Estimated annual value for a twelve-plant manufacturer (conservative):**

| Lever | Basis | Estimate |
|---|---|---|
| Regulatory penalties avoided | One to two serious or willful OSHA citations avoided per year (2024 maximums: $16,550 serious, $165,514 willful/repeat) | $165K to $330K |
| Audit preparation labor | Roster reconciliation cut from roughly 40 hours per plant per audit; 12 plants, 2 audits/year, $75/hour | ~$70K |
| Unplanned incident exposure | Catching mid-shift transfers into unqualified work; one recordable avoided at ~$40K direct and indirect | ~$40K |
| **Annual total (excluding tail risk)** | | **~$275K to $440K** |

The tail risk dominates the average: a single confined-space fatality citation and the
litigation behind it runs well over $1M all-in. ClearShift is a control against that
event, not only an efficiency play.

**Who owns which number.** The value lands on the metric each buyer is personally
measured on, not a generic efficiency figure. The VP of EHS carries the recordable
incident rate (TRIR/DART) and the audit-finding count on their annual goals; ClearShift
moves both by stopping the uncleared assignment before the shift and making the audit a
non-event. The CFO owns the tail-risk exposure and the audit-labor line. The plant
manager is measured on time-to-staff a compliant shift and the overtime that scrambling
burns. Same dollars, read against each scorecard.

## The integrated data journey

One dataset flows through every layer. No siloed demos stitched together.

| Stage | Where it lives | What it does |
|---|---|---|
| **Lakeflow** ingest | `pipeline/clearshift_pipeline.py`, `pipeline/raw/` | A Lakeflow Declarative Pipeline ingests the raw HR, schedule, qualification, training and incident files into bronze, cleans to silver, and builds the gold tables. |
| **Unity Catalog** govern | `horizontal_dev_serverless_catalog.clearshift.*` | Bronze/silver/gold land in Unity Catalog. The Genie space and the model registry read from here. |
| **Lakebase** serve | `lakebase/ddl/` (11 DDL files) | The operational store. Effective-dated requirements and dated credentials let past clearance be derived, not accumulated. Viewer scope (site and supervisor) is enforced on every read. |
| **ML** make it intelligent | `model/train.py`, `model/generate_history.py`, `model/score_batch.py`, `model/explain.py`, `model/monitor_drift.py` | A gradient-boosted model predicts the probability a worker's certification lapses before their next hazardous job, from leading behavioral signals. SHAP turns each score into a plain-language explanation based on the worker's own governed feature values. A PSI drift monitor compares the live feature and score distributions against the training baseline and raises a retrain flag when they shift. The score and the explanation persist to `gate.lapse_risk`. |
| **Optimization** decide | `app/backend/optimizer.py` | A CP-SAT (OR-Tools) optimizer turns those risk scores into a compliant crew plan. Hard compliance rules are constraints; lapse risk is the objective. |
| **Genie Agent** query | Genie space `01f1b7c3...`, `app/backend/genie.py`, `genie/benchmarks.md` | Natural-language questions over the gold tables, returning the SQL Genie ran so the answer is inspectable. Validated against a 15-question benchmark with expected SQL (87% on the last run). |
| **Databricks App** surface | `app/` (FastAPI + static SPA) | Nine operational views for the supervisor, auditor, and plant manager, including the live What-if studio. |

## Decisions and trade-offs

- **Reviewed intents plus Genie, not text-to-SQL alone.** This data gates whether a
  person may enter a confined space. A generated query that is subtly wrong would
  answer confidently and be believed. The assistant answers from a fixed set of
  reviewed queries by default and can hand off to Genie, which returns its SQL for
  inspection. Both inherit the caller's viewer scope.
- **Score in batch, optimize online.** The lapse-risk model scores nightly and
  persists to Lakebase; the What-if studio runs CP-SAT live. A solver must not call a
  serving endpoint in a loop, and staffing constraints change intraday, so scoring is
  the offline step and optimization is the online one.
- **The shift is the unit of assignment.** A person scheduled to a work center must
  hold every regulated qualification that seat demands at once. Modeling each
  requirement as a separate job would let the plan put two people on one seat.
- **CP-SAT over a heuristic.** Compliant assignment is constraint satisfaction with a
  cost objective. CP-SAT expresses the hard rules exactly and returns a provably
  optimal-within-model plan. Seats it cannot compliantly staff are reported
  explicitly rather than left silently unfilled.
- **Scope is the access model, not a filter.** A supervisor sees their crew, a plant
  manager sees their site, safety sees everything. In production this also belongs in
  row-level security in the database; doing it in one place in the app keeps the
  reference readable.
- **A score is not an explanation.** Every prediction persists a SHAP-based,
  plain-language reason grounded in the worker's own governed values ("expires in 12
  days, two prior lapses"), so a supervisor acts on why, not a bare number, and the
  attribution is a property of the model rather than a hand-written rule.
- **An exposed seat ships with a next move.** When the optimizer cannot compliantly
  staff a seat it does not stop at the reason: it names the nearest qualified
  substitute and what they would need, so the gap is actionable before the shift.

## How AI was used as a force multiplier

Built in Claude Code. AI generated the synthetic data generators, the pipeline and DDL
scaffolding, the optimizer, and the app, under direction on the domain model,
the compliance rules, and the modeling choices above. The decisions, the OSHA
framing, the value case, and the narrative are the author's.

## Execution evidence

See `evidence/` for committed run output of every layer: model training metrics, batch
scoring, the optimizer solve, the live What-if API response, the Genie transcript with
generated SQL and rows, the Genie benchmark evaluation (15 questions with expected SQL,
87% on the last run), per-prediction model explanations with their SHAP attribution, and a
drift-monitor run (PSI) that stays quiet on a stable population and raises the retrain flag
on a shifted one. The evaluator reads text; the evidence is text.

## Data

Facility names are real and public. Every person, identifier, credential, schedule row
and incident is invented. No production or customer data appears anywhere in this
repository.
