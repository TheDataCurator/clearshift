# ClearShift deck

The canonical, branded deck is the Google Slides presentation, exported to
`deck/ClearShift_deck.pdf` (the file attached to the FE Bar submission). This
Markdown mirrors that deck's content and speaker notes as a plain-text record.
Talking points are the presenter's notes, not on-slide text.

---

## 1. ClearShift
No one performs regulated work without proven qualification.
Hayley Horn, Sr SA.

---

## 2. Safety is a financial control

- **$167B** — U.S. cost of work injuries a year (National Safety Council)
- **$165K** — per willful OSHA citation; $16,550 per serious violation
- **$1M+** — all-in for a single fatality event and its litigation

> **Notes:** The executive stakes. Hazardous work, confined space, hot work, lockout/tagout, is where people get seriously hurt, and qualification is the control that prevents it. Injuries cost U.S. employers about $167 billion a year; a willful OSHA citation runs to $165K; a single fatality event with litigation exceeds $1M. Safety here is a boardroom number, not a checklist. The question is whether you can prove qualification before the work happens.

---

## 3. Trained is not the same as cleared to work

- **The gap** — a worker can be scheduled into hazardous work they are not currently qualified to perform.
- **The blind spot** — data is fragmented across HR, the scheduler, and the LMS, so no one can answer in time.

> **Notes:** The systems of record capture training completion, not who is cleared to work a seat tomorrow. First-time hazardous work slips through without a supervisor. Because the data is fragmented, the exposure is invisible until an incident or an auditor surfaces it. That is the gap ClearShift closes.

---

## 4. One governed control closes the gap

A single control runs across the day: **Evening** gate the shift (clear or flag), **Shift** compliant crew (optimized from your workforce), **Audit day** prove readiness (on demand). The lapse-risk model feeds the plan.

> **Notes:** One governed control, across the day. Evening: the schedule is checked against what each seat requires and cleared or flagged before the shift. Shift: an optimizer staffs a compliant crew from the qualified pool, fed by the lapse-risk model. Audit day: readiness is proven on demand from dated records. The next slides show the model, the plan, and Genie in action.

---

## 5. Predict lapses with time to act

Lapse-risk model feature importance, ROC AUC 0.88. Days to expiry carries most of the signal; behavioral signals (proactive renewal, training backlog, prior lapses) add the early warning. Per worker, SHAP turns the score into a plain-language reason grounded in their own record.

> **Notes:** A rule tells you who already expired. The model predicts who is about to lapse, and why, in time to renew before the shift is exposed. Gradient-boosted, ROC AUC 0.88, on leading signals. Real machine learning, not an expiry lookup. And every score carries a SHAP-based explanation in plain language, grounded in the worker's own governed values (expires in 12 days, two prior lapses), so a supervisor sees the reason, not just a number.

---

## 6. The optimizer staffs a compliant crew from your workforce, and calls out risk

The What-if studio: a CP-SAT optimizer assigns the qualified pool to tomorrow's regulated seats, prefers the lowest-lapse-risk workers, and names the seats it cannot compliantly staff, with the reason and the nearest qualified substitute to pursue.

> **Notes:** This is the decision, not a report. Hard compliance rules are constraints, never traded off: hold every required qualification, supervise every first performance, no double-booking. In the live scenario it clears exposed seats by moving the right people, and for the seats it cannot staff it names why and the closest substitute or next step, so you act before the shift.

---

## 7. Ask the questions to keep on top of your data

Ask ClearShift with Genie: natural-language questions over the governed gold tables, returning the SQL it ran. Validated against a 15-question benchmark (87% on the last run).

> **Notes:** For the questions no one anticipated. Natural language over the same governed gold tables. It returns the SQL it ran, so the answer is inspectable, not taken on trust, and it is scoped to who is asking. And the space is benchmarked against 15 questions with expected SQL, 87% on the last run, so reliability is measured, not asserted. Governance does not stop at the dashboard.

---

## 8. Safer floors, clean audits, leaner staffing

The proof is in the demo.

- **Safer floors** — fewer unqualified-work exposures reaching the floor.
- **Clean audits** — readiness proven on demand, fewer citations and findings.
- **Leaner staffing** — compliant substitutes from your own workforce, faster time-to-staff.

> **Notes:** Roughly $275K to $440K a year before tail risk. Read it against the number each buyer owns: the VP of EHS carries recordable rate (TRIR/DART) and audit findings; the CFO owns tail-risk exposure and audit labor; the plant manager, time-to-staff a compliant shift and overtime. Same dollars, each scorecard. For the sponsor, the number and the tail risk; for the domain owner, the daily workflow.

---

## 9. The Architecture

One dataset flows through every layer, no silos. Unified data pipeline: Ingest → Govern → Serve → Predict → Decide → Query (Lakeflow, Unity Catalog, Lakebase, ML, CP-SAT, Genie, Databricks App).

> **Notes:** The integration is the point. One dataset flows through every layer: Lakeflow ingests it, Unity Catalog governs it, Lakebase serves it, the model predicts, the optimizer decides, Genie answers, the app surfaces it. One platform, governance the whole way.

---

## 10. Next steps

Prove it in weeks. Expand where it matters. Adoption path: **Foundation** (unify HR, scheduler, LMS; prove audit readiness) → **Predict & gate** (lapse-risk model and pre-shift clearance where exposure is highest) → **Optimize at scale** (CP-SAT compliant crew planning across every plant).

> **Notes:** Close on the path, not a rip-and-replace. It sits beside the systems you run and answers the question they cannot. Start where the exposure is, prove it, expand.

---

## 11. No one performs regulated work without proven qualification.

Closing statement.
