# ClearShift: golden walkthrough and roleplay guide

The demo script for the FE Bar AI roleplay. Two personas are in the room at once: a
**business stakeholder** (the VP of EHS or plant operations leader who funds the
decision) and a **technical stakeholder** (the data lead or architect who has to live
with it). Lead with the outcome, keep the demo tight, and switch altitude mid-answer.

Total target: 12 to 15 minutes of walkthrough, then objections.

> **Before you present (data freshness):** the demo is date-relative. Pre-shift
> clearance and the What-if studio show "tomorrow", and the seed data is anchored
> to the day it was loaded. If it has been more than a day since the last load,
> reseed so "tomorrow" has schedule data: from the repo root run the DDL files in
> `lakebase/ddl/` in order against the `clearshift` database, then
> `python model/score_batch.py`. On a fresh reseed the Peoria scenario shows seven
> regulated seats with five exposed.

---

## 0. Demo setup (60 seconds, before you touch the app)

Say this first, before any screen:

> "I'm going to show you ClearShift, built for a mid-size manufacturer with hazardous
> regulated work across a dozen plants. The problem: a worker can be scheduled tomorrow
> into confined-space or hot-work they are not currently qualified to perform, and no
> one sees it until an incident or an auditor does. ClearShift checks tomorrow's
> schedule against what every job requires, predicts who is about to lapse, plans a
> compliant crew, and proves audit readiness on demand. I'll walk one plant, Peoria,
> through a normal day."

Frame the two questions you will answer: **are we compliantly staffed tomorrow**, and
**can we prove it when the auditor calls**.

---

## 1. The problem (tell) — 1 minute

Open on the **Home** view. Name the stakes in their terms:

- One willful OSHA citation is $165K; a confined-space fatality citation runs past $1M all-in.
- Audit prep is 40 hours per plant, per audit, reconciling rosters by hand.
- The data exists across HR, the scheduler, and the LMS. It is fragmented, so no one can answer in time.

> **Land it:** "This is a control problem, not a reporting problem. The cost of being wrong is asymmetric."

---

## 2. Pre-shift clearance (show) — 2 minutes

Go to **Pre-shift clearance**.

- Tell: "This is tomorrow's schedule at Peoria, checked against what each seat requires."
- Show: point to a **NOT CLEARED** worker. Read the plain-language reason (for example, a certification authorized for another site, not this one).
- Show: point to a **first performance** flag, where a first-time hazardous task needs a supervisor present.
- Tell: "A clock-in gate checks at the door. We also catch the worker moved mid-shift into work they were not scheduled for."

> **Land it:** "The supervisor sees this the evening before, not after the incident. The reason is actionable, not a red cell."

---

## 3. Audit readiness (show) — 2 minutes

Go to **Audit roster** and **OSHA audit**.

- Show: every regulated requirement at the site and whether it is currently held.
- Show: card serials, trainers, evidence references, ready to spot-check.
- Tell: "This is derived from dated records, so we can prove what was required and held on any past date, not just today."

> **Land it:** "When the auditor arrives, the roster is already the answer. Forty hours becomes minutes, and a finding becomes a non-event."

---

## 4. The model (tell, then show) — 2 minutes

Go to **Coverage and what-if**, top of the What-if studio, and reference the worker risk.

- Tell: "A rule tells you who already expired. We predict who is about to lapse, before the shift is exposed."
- Show: the workers listed with a lapse-risk score. Note the already-lapsed certification scores highest.
- Tell: "Gradient-boosted model, ROC AUC 0.88, on leading signals: days to expiry, renewal behavior, training backlog, prior lapses, schedule pressure. It is machine learning, not an expiry lookup."

> **Land it:** "This is what lets us act early. The score feeds the plan you're about to see."

---

## 5. The What-if studio (show, the centerpiece) — 3 minutes

Stay on **Coverage and what-if**. The plan is already on screen: it runs automatically every evening at 6:00 PM, once tomorrow's schedule publishes. **Refresh plan** re-runs it on demand after a late swap or call-off.

- Tell: "Seven regulated seats tomorrow. Five are exposed under the current schedule."
- Show: the nightly plan, then click Refresh plan. "A CP-SAT optimizer built a compliant plan overnight. It cleared two exposed seats by moving the right qualified people, and it preferred the workers whose own certification is least likely to lapse."
- Show: point to the re-planned assignments and the lapse-risk pills.
- Show: the **Still exposed** section. Read the three reasons: no worker holds the full requirement, a first performance with no supervisor available, and capacity fully committed.
- Tell: "Hard compliance rules are constraints. The optimizer will never trade them off. It would rather tell you a seat has no compliant answer than quietly fill it."

> **Land it:** "This is the decision, not a report. It staffs from the workforce you already have, and it tells you exactly where you're exposed so you act before the shift, not after."

---

## 6. Genie (show) — 1.5 minutes

Go to **Ask ClearShift**, switch the engine toggle to **Genie**.

- Show: click the suggestion chip "How many workers have a certification expiring in the next 90 days, by site?" Read the answer. (This phrasing answers directly; more open-ended questions sometimes prompt Genie to ask a clarifying question first, which is fine but slower on stage.)
- Show: expand **SQL Genie ran**. "It shows the query, over the governed gold tables. The answer is inspectable, not taken on trust, and it is scoped to who is asking."

> **Land it:** "For the questions no one anticipated. Plain language in, governed answer out, with the SQL shown."

---

## 7. Close (tell) — 1 minute

Return to Home or the deck close slide.

- "One dataset flows through every layer: Lakeflow ingests it, Unity Catalog governs it, Lakebase serves it, the model predicts, the optimizer decides, Genie answers, the app surfaces it."
- "Estimated $275K to $440K a year for twelve plants before tail risk, and the tail risk is what funds it."
- "It sits beside the systems you run. Start where the exposure is highest, prove it, expand."

---

## Objection handling

### Business stakeholder (cost, risk, time to value)

- **"We already have an LMS."** "The LMS records course completion. It cannot tell you if tomorrow's shift is compliantly staffed, or plan a substitute. ClearShift consumes what the LMS records and answers the operational question. It is additive, not a replacement."
- **"How do I know the number is real?"** "The average case is penalties avoided plus 40 hours per plant per audit in labor. Both are measurable. I'd anchor the business case on one avoided willful citation and the audit labor, and treat the fatality tail risk as the reason it is a board-level control."
- **"How long to value?"** "Audit readiness lands in weeks on the data you already have. The model and optimizer come next, at the plants with the highest exposure. No rip and replace."
- **"What if the optimizer is wrong?"** "It cannot violate a compliance rule; those are hard constraints. The worst case is it reports a seat as unstaffable, which is exactly the signal you want before the shift."

### Technical stakeholder (architecture, data quality, security, integration)

- **"Where does the data come from?"** "Three source systems: HR for employees and supervisors, the scheduler for assignments, the LMS for qualifications and training. Lakeflow ingests to bronze, we clean to silver, and build gold. The views name stand-in tables you swap for your synced UKG and HCM tables; only the schema qualifier changes."
- **"Why not text-to-SQL everywhere?"** "This data gates entry to a confined space. A subtly wrong generated query would answer confidently and be believed. The assistant defaults to reviewed queries; Genie is available and returns its SQL for inspection. Both inherit the caller's scope."
- **"Why score in batch instead of calling the model live?"** "A solver must not call a serving endpoint in a loop, and staffing constraints change intraday. So the model scores nightly to a Lakebase table, and the optimizer runs live on those scores. Scoring is the offline step, optimization is the online one."
- **"How is access controlled?"** "Site and supervisor are the access model, not a filter. A crew supervisor sees their crew, a plant manager their site, safety everything, an unknown principal nothing. In production this also belongs in row-level security in the database; the app enforces it in one place so the reference stays readable."
- **"Is this real ML or a rule?"** "Gradient-boosted classifier, ROC AUC 0.88, with feature importances that match the data-generating process. It predicts lapse probability from behavioral signals, so it warns early rather than reporting expiries."
- **"Freshness?"** "The join assumes the three sources refresh daily. If HR lagged on a monthly snapshot, a mid-month role change would be invisible for up to a month; that is a stated assumption to confirm per deployment, not a silent gap."

---

## Altitude switching (the skill they score)

When the technical stakeholder asks for architecture, give the real detail (batch scoring,
CP-SAT constraints, effective-dated requirements), then in the same breath return to the
business: "and the reason that matters to you is the plan is provably compliant and
reproducible." When the business stakeholder asks about cost, lead with the number, then
offer one line of how it is computed for the technical stakeholder listening. Never leave
one persona behind to satisfy the other.
