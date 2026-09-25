# Execution evidence

Committed run output, readable as text, showing each layer actually ran. Regenerate
any of it by pointing the app and the model scripts at a Postgres named `clearshift`
seeded from `lakebase/ddl/` (see the repo README).

| File | What it proves | How it was produced |
|---|---|---|
| `01_model_training.txt` | The lapse-risk model trains and performs (ROC AUC, precision/recall, feature importance). Feature importance is led by `days_to_expiry`, matching the documented data-generating process. | `python model/train.py` (local MLflow, no workspace) |
| `02_batch_scoring.txt` | The trained model scores every (worker, qualification) and persists to `gate.lapse_risk`. The already-lapsed HOT_WORK cert scores highest. | `python model/score_batch.py` |
| `03_optimizer_demo.txt` | The CP-SAT optimizer solves a scenario to OPTIMAL, staffs a first-performance job with a supervisor, and reports the job with no eligible worker as uncovered. | `python model/optimizer.py` |
| `04_whatif_live.json` | The integrated What-if endpoint: reads Lakebase views + persisted model scores, runs CP-SAT live, returns a compliant plan and the seats it cannot staff, each with a reason. | `GET /api/whatif/scenario`, `POST /api/whatif/solve` |
| `05_genie_transcript.txt` | The Genie Agent answers natural-language questions over the Unity Catalog gold tables, returning the SQL it ran and the rows. Includes Genie correctly declining an out-of-scope question. | `POST /api/ask engine=genie` against the live Genie space |

The dates in the run output are the capture date; "tomorrow" in the What-if resolves to
the day after capture.
