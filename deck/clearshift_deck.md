# ClearShift
### No one performs regulated work without proven qualification.
Qualification gating, pre-shift safety, and compliant crew planning on Databricks.

> **Talking points:** ClearShift is a working build on the Databricks Platform for manufacturers with hazardous, regulated work. It answers one question the learning system cannot: is tomorrow's shift compliantly staffed, and if not, what do we do about it before the shift starts.

---

## The problem many plant and EHS leaders face

- A worker can be scheduled tomorrow into work they are not currently qualified to perform.
- The learning system records who took a course. It cannot tell you who is cleared to work a seat tomorrow.
- Audit readiness is reconstructed by hand, plant by plant, the week an auditor calls.
- First-time hazardous work slips through without a supervisor present.
- The gap is invisible until an incident or a citation makes it visible.

> **Talking points:** Every manufacturer with confined space, hot work, or lockout/tagout carries this exposure daily. The data exists, in the HR system, the scheduler, the LMS, but it is fragmented, so no one can answer the operational question in time to act.

---

## What that exposure costs

# $165K
per willful or repeat OSHA citation (2024 maximum). Serious violations run to $16,550 each.

# >$1M
all-in for a single confined-space fatality citation and the litigation behind it.

# 40 hrs
per plant, per audit, spent reconciling rosters by hand today.

> **Talking points:** The average-case value is real: penalties avoided plus audit labor. But the tail risk is what funds this. One prevented confined-space incident dwarfs the cost of the platform. This is a control, not only an efficiency play.

---

## ClearShift: a governed foundation, made intelligent

**FOUNDATION** — All qualification, schedule, and requirement data, unified and effective-dated on Databricks.

**GOVERNANCE** — Site and supervisor are the access model. Every answer is scoped and traceable to its source.

**INTELLIGENCE** — A model predicts who will lapse; an optimizer plans a compliant crew; Genie answers in plain language.

> **Talking points:** Same arc as any Databricks data intelligence story: get the foundation right, govern it, then make it intelligent. The difference here is the intelligence makes a compliance decision, not a dashboard.

---

## Pre-shift clearance: the gate

- Tomorrow's schedule, checked against what each job and work center requires.
- One verdict per person: cleared, first performance, or not cleared, with a plain reason.
- Requirements are effective-dated, so the check reflects what was required on the day.
- Catches the case a clock-in gate misses: a worker moved mid-shift into work they are not qualified for.

> **Talking points:** This is the daily driver. A supervisor sees tomorrow's crew before the shift, not after. The reason is in plain language so it is actionable, not a red cell on a spreadsheet.

---

## Audit readiness: prove it the day they ask

- Every regulated requirement at a site, and whether it is currently held.
- Card serials, trainers, evidence references, ready to spot-check.
- The answer is derived from dated records, not accumulated, so historical clearance is provable.

# From 40 hrs to minutes
audit roster reconciliation, per plant.

> **Talking points:** When the auditor arrives, the roster is already the answer. No fire drill. This is where the audit-labor savings land, and where a finding becomes a non-event.

---

## Intelligence: predict who will lapse, do not just report who expired

- A gradient-boosted model scores every worker-certification pair: probability the certification lapses before the next hazardous job.
- Leading signals: days to expiry, renewal behavior, training backlog, prior lapses, schedule pressure.
- Measured performance: ROC AUC 0.88. Expiry proximity carries most of the signal; behavior adds the early warning.

> **Talking points:** A rule tells you who is already expired. The model tells you who is about to lapse and why, in time to renew before the shift is exposed. This is real machine learning, not an expiry date lookup.

---

## What-if studio: a compliant crew, solved

- A CP-SAT optimizer assigns the qualified pool to tomorrow's regulated seats.
- Hard compliance rules are constraints, never traded off: hold every required qualification, supervise every first performance, no double-booking.
- Among compliant plans, it prefers workers whose own certification is least likely to lapse.
- Seats it cannot staff are named, with the reason, so you act before the shift.

> **Talking points:** This is the decision, not a report. In the live scenario it clears exposed seats by moving the right qualified people, and it tells you exactly which seats have no compliant answer and why. Scarce low-risk capacity gets spent where it matters.

---

## Genie: ask in plain language, see the SQL

- Natural-language questions over the governed gold tables.
- Returns the SQL it ran, so the answer is inspectable, not taken on trust.
- Answers within the caller's scope, and declines questions outside the data.

> **Talking points:** For the questions no one anticipated. A safety lead asks in plain English and gets an answer grounded in the same governed tables, with the query shown. Governance does not stop at the dashboard.

---

## The outcomes, in your KPIs

**RECORDABLE INCIDENT RATE** — Fewer unqualified-work exposures reaching the floor.

**CITATIONS AND FINDINGS** — Audit readiness proven on demand, not reconstructed.

**BACKFILL SPEND** — Compliant substitutes found from the existing workforce, not overtime or contractors.

**TIME TO STAFF A COMPLIANT SHIFT** — From a manual scramble to a solved plan.

# ~$275K to $440K
estimated annual value for a twelve-plant manufacturer, before tail risk.

> **Talking points:** For the executive sponsor, the number and the tail risk. For the domain owner, the daily workflow: clearance, audit readiness, and the what-if plan. Both get what they came for.

---

## Built as one connected journey

**Lakeflow** ingest → **Unity Catalog** govern → **Lakebase** serve → **ML** predict → **CP-SAT** decide → **Genie** query → **Databricks App** surface.

One dataset flows through every layer. No siloed parts.

> **Talking points:** The integration is the point. Raw operational data becomes a compliance decision and a plain-language answer, on one platform, with governance that travels the whole way.

---

## Accelerate time to value. Build for the future.

- Start with the foundation you already have: HR, scheduler, LMS.
- Prove audit readiness in weeks, not a rebuild.
- Add the model and the optimizer where the exposure is highest.
- A reference implementation, adapted to your plants, not deployed as-is.

> **Talking points:** Close on the path. This is not a rip-and-replace. It sits beside the systems you run and answers the question they cannot. Start where the exposure is, prove it, expand.
