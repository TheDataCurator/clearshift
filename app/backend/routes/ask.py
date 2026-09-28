"""Qualification assistant.

Questions resolve to named, reviewed queries against the same views the rest of
the application uses. Nothing is generated on the fly.

Why intent matching rather than text-to-SQL: this data gates whether a person may
enter a confined space. A generated query that is subtly wrong would answer
confidently and be believed. A fixed set of reviewed queries can only be wrong in
ways someone has already had the chance to catch, and every answer inherits the
caller's viewer scope for free.

On Databricks the same pattern hands off to a Genie space over these views, which
widens the question surface without giving up the governance. The intents below
are the fallback and the specification of what good answers look like.
"""

from __future__ import annotations

import re
from datetime import date, timedelta

from fastapi import APIRouter, Body, Query

from backend import config, db, genie

router = APIRouter(prefix="/api/ask", tags=["ask"])

SUGGESTIONS = [
    "Who is blocked from working tomorrow?",
    "How many workers have a certification expiring in the next 90 days, by site?",
    "Is Peoria ready for the audit?",
    "Where is cover thin?",
    "Who could cover blast and coating?",
    "What lapses in the next 90 days?",
    "Who is overdue on compliance training?",
    "Which manager has the worst completion?",
]


def _fmt_people(rows: list[dict], line) -> str:
    return "\n".join("• " + line(r) for r in rows)


# ---------------------------------------------------------------------------
# Intents
# ---------------------------------------------------------------------------

def _blocked(principal: str) -> dict:
    predicate, params = db.scope_clause(principal)
    params["d"] = date.today() + timedelta(days=1)
    rows = db.query(
        f"""
        SELECT DISTINCT employee_name, work_center_desc, qualification_name, reason
          FROM gate.v_shift_clearance
         WHERE work_date = %(d)s AND clearance = 'NOT_CLEARED' AND {predicate}
         ORDER BY employee_name
        """,
        params,
    )
    if not rows:
        return {"answer": "Nobody in your scope is blocked from tomorrow's scheduled work.",
                "view": "shift", "rows": []}
    names = sorted({r["employee_name"] for r in rows})
    body = _fmt_people(rows, lambda r: f"{r['employee_name']} — {r['work_center_desc']} — {r['reason']}")
    return {
        "answer": f"{len(names)} {'person is' if len(names) == 1 else 'people are'} "
                  f"blocked from tomorrow's scheduled work.\n\n{body}",
        "view": "shift",
        "rows": rows,
    }


def _supervision(principal: str) -> dict:
    predicate, params = db.scope_clause(principal)
    params["d"] = date.today() + timedelta(days=1)
    rows = db.query(
        f"""
        SELECT DISTINCT employee_name, work_center_desc, qualification_name, supervisor_name
          FROM gate.v_shift_clearance
         WHERE work_date = %(d)s AND clearance = 'SUPERVISION_REQUIRED' AND {predicate}
        """,
        params,
    )
    if not rows:
        return {"answer": "No first performances are outstanding for tomorrow.", "view": "shift", "rows": []}
    body = _fmt_people(
        rows,
        lambda r: f"{r['employee_name']} — first time performing {r['qualification_name']} "
                  f"in {r['work_center_desc']}. Supervisor of record: {r['supervisor_name']}.",
    )
    return {
        "answer": f"{len(rows)} first {'performance' if len(rows) == 1 else 'performances'} "
                  f"need a supervisor present tomorrow.\n\n{body}",
        "view": "shift",
        "rows": rows,
    }


def _audit_ready(principal: str, site_hint: str | None) -> dict:
    predicate, params = db.scope_clause(principal)
    rows = db.query(
        f"""
        SELECT location, employee_name, job_description, qualification_name, qualification_state
          FROM gate.v_site_roster
         WHERE is_regulated
           AND qualification_state NOT IN ('CURRENT','EXPIRING')
           AND {predicate}
         ORDER BY location, employee_name
        """,
        params,
    )
    if site_hint:
        rows = [r for r in rows if site_hint.lower() in r["location"].lower()]
    where = site_hint.title() if site_hint else "your scope"
    if not rows:
        return {"answer": f"Every regulated requirement in {where} is currently held. "
                          f"The roster would stand up to an audit as of today.",
                "view": "site", "rows": []}
    body = _fmt_people(
        rows,
        lambda r: f"{r['employee_name']} ({r['job_description']}) — {r['qualification_name']} "
                  f"— {r['qualification_state'].replace('_',' ').lower()}",
    )
    n = len({r["employee_name"] for r in rows})
    return {
        "answer": f"No. {n} {'person has' if n == 1 else 'people have'} an unmet regulated "
                  f"requirement in {where}.\n\n{body}",
        "view": "site",
        "rows": rows,
    }


def _thin_cover(_: str) -> dict:
    rows = db.query(
        """
        SELECT location, qualification_name, qualified_now, cover_state
          FROM gate.v_coverage
         WHERE is_regulated AND cover_state <> 'ADEQUATE'
         ORDER BY qualified_now, location
        """
    )
    if not rows:
        return {"answer": "Cover is adequate for every regulated credential at onboarded sites.",
                "view": "coverage", "rows": []}
    none_ = [r for r in rows if r["qualified_now"] == 0]
    single = [r for r in rows if r["qualified_now"] == 1]
    lead = []
    if none_:
        lead.append(f"{len(none_)} with nobody qualified at all")
    if single:
        lead.append(f"{len(single)} resting on a single person")
    body = _fmt_people(
        rows,
        lambda r: f"{r['qualification_name']} at {r['location']} — {r['qualified_now']} qualified "
                  f"({r['cover_state'].replace('_',' ').lower()})",
    )
    return {
        "answer": f"{len(rows)} regulated credentials are thin"
                  + (f", including {' and '.join(lead)}" if lead else "") + f".\n\n{body}",
        "view": "coverage",
        "rows": rows,
    }


def _opportunity(_: str, qual_hint: str | None) -> dict:
    rows = db.query(
        """
        SELECT location, qualification_id, qualification_name, cover_state, qualified_now,
               employee_id, employee_name, job_description, department, supervisor_name,
               route, credentials_held, already_assigned_to_such_work,
               previously_revoked, revoked_reason
          FROM gate.v_credential_opportunity
         WHERE cover_state IN ('NO_COVER','SINGLE_POINT')
         ORDER BY location, qualification_name, readiness_score DESC
        """
    )
    if qual_hint:
        want = QUAL_TERMS.get(qual_hint)
        rows = [r for r in rows if r["qualification_id"] == want] if want else []
    if not rows:
        if qual_hint:
            return {"answer": f"No coverage gap for {qual_hint} with internal candidates. "
                              f"Ask where cover is thin to see the credentials that do have one.",
                    "view": "coverage", "rows": []}
        return {"answer": "No critical coverage gaps with internal candidates right now.",
                "view": "coverage", "rows": []}

    # Best three candidates per gap
    seen: dict[tuple, int] = {}
    picked = []
    for r in rows:
        k = (r["location"], r["qualification_name"])
        seen[k] = seen.get(k, 0) + 1
        if seen[k] <= 3:
            picked.append(r)

    lines = []
    for k in dict.fromkeys((r["location"], r["qualification_name"]) for r in picked):
        loc, qual = k
        group = [r for r in picked if (r["location"], r["qualification_name"]) == k]
        lines.append(f"\n{qual} at {loc} — {group[0]['qualified_now']} qualified today:")
        for r in group:
            note = " (renewal only)" if r["route"] == "RENEW" else ""
            if r["previously_revoked"]:
                note = f" — previously revoked: {r['revoked_reason'] or 'reason not recorded'}"
            near = ", already assigned to work requiring it" if r["already_assigned_to_such_work"] else ""
            lines.append(f"  • {r['employee_name']} ({r['job_description']}), holds "
                         f"{r['credentials_held']} other regulated credentials{near}{note}")
    return {
        "answer": "Certifying an existing employee is faster than hiring. Best-placed candidates:\n"
                  + "\n".join(lines),
        "view": "coverage",
        "rows": picked,
    }


def _development(principal: str) -> dict:
    predicate, params = db.scope_clause(principal)
    rows = db.query(
        f"""
        SELECT employee_name, department, title, status, score
          FROM gate.v_learning_assignment
         WHERE category = 'DEVELOPMENT' AND {predicate}
         ORDER BY CASE status WHEN 'IN_PROGRESS' THEN 1 ELSE 2 END, employee_name
        """,
        params,
    )
    if not rows:
        return {"answer": "No development enrolments in your scope.", "view": "learning", "rows": []}
    body = _fmt_people(
        rows,
        lambda r: f"{r['employee_name']} ({r['department']}) — {r['title']} — "
                  f"{r['status'].replace('_',' ').lower()}"
                  + (f", scored {r['score']}" if r["score"] is not None else ""),
    )
    active = sum(1 for r in rows if r["status"] == "IN_PROGRESS")
    return {
        "answer": f"{len(rows)} development enrolments, {active} in progress. "
                  f"These are elective and carry no due date.\n\n{body}",
        "view": "learning",
        "rows": rows,
    }


def _renewals(principal: str) -> dict:
    predicate, params = db.scope_clause(principal)
    rows = db.query(
        f"SELECT employee_name, location, qualification_name, days_until_expiry, bucket "
        f"FROM gate.v_renewal_pipeline WHERE {predicate} ORDER BY days_until_expiry",
        params,
    )
    if not rows:
        return {"answer": "Nothing lapses within ninety days in your scope.", "view": "renewal", "rows": []}
    lapsed = [r for r in rows if r["days_until_expiry"] < 0]
    body = _fmt_people(
        rows,
        lambda r: f"{r['employee_name']} — {r['qualification_name']} — "
                  + (f"lapsed {abs(r['days_until_expiry'])} days ago"
                     if r["days_until_expiry"] < 0 else f"{r['days_until_expiry']} days"),
    )
    lead = f"{len(rows)} credentials lapse within ninety days"
    if lapsed:
        lead += f", and {len(lapsed)} {'has' if len(lapsed) == 1 else 'have'} already lapsed"
    return {"answer": f"{lead}.\n\n{body}", "view": "renewal", "rows": rows}


def _transfers(principal: str) -> dict:
    predicate, params = db.scope_clause(principal)
    rows = db.query(
        f"SELECT employee_name, work_date, scheduled_wc_desc, actual_wc_desc, qualification_name "
        f"FROM gate.v_unplanned_transfer WHERE {predicate} ORDER BY work_date DESC",
        params,
    )
    if not rows:
        return {"answer": "No unplanned transfers into work requiring credentials the person did not hold.",
                "view": "shift", "rows": []}
    body = _fmt_people(
        rows,
        lambda r: f"{r['employee_name']} on {r['work_date']} — scheduled {r['scheduled_wc_desc']}, "
                  f"worked {r['actual_wc_desc']} — {r['qualification_name']} not held",
    )
    return {
        "answer": "A clock-in check would have cleared these people. They moved mid-shift into work "
                  f"requiring credentials they did not hold.\n\n{body}",
        "view": "shift",
        "rows": rows,
    }


def _compliance_overdue(principal: str) -> dict:
    predicate, params = db.scope_clause(principal)
    rows = db.query(
        f"""
        SELECT employee_name, department, title, due_on, days_until_due, supervisor_name
          FROM gate.v_learning_assignment
         WHERE category = 'COMPLIANCE' AND status = 'OVERDUE' AND {predicate}
         ORDER BY days_until_due
        """,
        params,
    )
    if not rows:
        return {"answer": "No compliance training is overdue in your scope.",
                "view": "learning", "rows": []}
    body = _fmt_people(
        rows,
        lambda r: f"{r['employee_name']} ({r['department']}) — {r['title']} — "
                  f"{abs(r['days_until_due'])} days overdue",
    )
    n = len({r["employee_name"] for r in rows})
    return {
        "answer": f"{len(rows)} overdue compliance {'item' if len(rows) == 1 else 'items'} "
                  f"across {n} {'person' if n == 1 else 'people'}.\n\n{body}",
        "view": "learning",
        "rows": rows,
    }


def _team_completion(principal: str) -> dict:
    predicate, params = db.scope_clause(principal)
    rows = db.query(
        f"SELECT * FROM gate.v_team_compliance WHERE {predicate} ORDER BY compliance_pct NULLS LAST",
        params,
    )
    if not rows:
        return {"answer": "No reporting lines in your scope.", "view": "learning", "rows": []}
    body = _fmt_people(
        rows,
        lambda r: f"{r['supervisor_name']} — {r['compliance_complete']} of "
                  f"{r['compliance_assigned']} complete"
                  + (f", {r['compliance_overdue']} overdue" if r["compliance_overdue"] else "")
                  + (f" ({r['compliance_pct']}%)" if r["compliance_pct"] is not None else ""),
    )
    worst = rows[0]
    return {
        "answer": f"{worst['supervisor_name']} has the lowest completion at "
                  f"{worst['compliance_pct']}%.\n\n{body}",
        "view": "learning",
        "rows": rows,
    }


def _person_record(principal: str, name_hint: str) -> dict:
    """One person's record, plant and corporate together.

    Deliberately spans both modules: an employee has one record, and answering
    from only half of it would be misleading.
    """
    predicate, params = db.scope_clause(principal)
    params["n"] = f"%{name_hint}%"
    who = db.query(
        f"SELECT employee_id, employee_name, job_description, department, location, audit_status "
        f"FROM gate.v_training_matrix WHERE employee_name ILIKE %(n)s AND {predicate} LIMIT 1",
        params,
    )
    if not who:
        return {"answer": f"No one matching \"{name_hint}\" in your scope.", "view": None, "rows": []}
    p = who[0]

    creds = db.query(
        "SELECT qualification_name, state, expires_on FROM gate.v_qualification_state "
        "WHERE employee_id = %(e)s AND is_regulated ORDER BY qualification_name",
        {"e": p["employee_id"]},
    )
    learn = db.query(
        "SELECT title, category, status, due_on FROM gate.v_learning_assignment "
        "WHERE employee_id = %(e)s ORDER BY category, title",
        {"e": p["employee_id"]},
    )

    lines = [f"{p['employee_name']} — {p['job_description']}, {p['department']}, {p['location']}"]
    if creds:
        lines.append("\nRegulated credentials:")
        for c in creds:
            lines.append(f"  • {c['qualification_name']} — {c['state'].replace('_',' ').lower()}"
                         + (f", expires {c['expires_on']}" if c["expires_on"] else ""))
    if learn:
        lines.append("\nLearning:")
        for l in learn:
            lines.append(f"  • {l['title']} ({l['category'].lower()}) — {l['status'].replace('_',' ').lower()}"
                         + (f", due {l['due_on']}" if l["due_on"] else ""))
    if not creds and not learn:
        lines.append("\nNo credentials or learning records.")

    return {"answer": "\n".join(lines),
            "view": "learning" if learn and not creds else "site",
            "rows": []}


# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

SITES = ["peoria", "grand rapids", "aurora", "rochester", "erie", "springfield",
         "dubuque", "toledo", "boise", "wichita", "lincoln", "reno"]

# Everyday terms mapped to the credential they refer to. People ask about a
# forklift, not a powered industrial truck, and the two share no words.
QUAL_TERMS = {
    "confined space": "CONFINED_SPACE",
    "tank":           "CONFINED_SPACE",
    "vessel":         "CONFINED_SPACE",
    "hot work":       "HOT_WORK",
    "welding":        "HOT_WORK",
    "weld":           "HOT_WORK",
    "forklift":       "POWERED_TRUCK",
    "fork lift":      "POWERED_TRUCK",
    "powered industrial truck": "POWERED_TRUCK",
    "pit":            "POWERED_TRUCK",
    "lift truck":     "POWERED_TRUCK",
    "lockout":        "LOTO",
    "loto":           "LOTO",
    "tagout":         "LOTO",
    "respirator":     "RESPIRATOR",
    "respiratory":    "RESPIRATOR",
    "fall protection": "FALL_PROTECT",
    "fall":           "FALL_PROTECT",
    "crane":          "CRANE_SIGNAL",
    "hoist":          "CRANE_SIGNAL",
    "signalling":     "CRANE_SIGNAL",
    "signaling":      "CRANE_SIGNAL",
    "blast":          "BLAST_COATING",
    "coating":        "BLAST_COATING",
    "paint":          "BLAST_COATING",
    "first aid":      "FIRST_AID_CPR",
    "cpr":            "FIRST_AID_CPR",
}

# Longest first, so "fall protection" wins over "fall".
QUALS = sorted(QUAL_TERMS, key=len, reverse=True)


def route(q: str, principal: str) -> dict:
    t = q.lower().strip()
    site = next((s for s in SITES if s in t), None)
    qual = next((k for k in QUALS if k in t), None)

    def has(*words): return any(w in t for w in words)

    if has("one credential", "one cert", "one more", "instead of hiring", "avoid hiring",
           "who could cover", "who could close", "who could", "who should get", "what if",
           "upskill", "cross-train", "cross train", "candidates"):
        return _opportunity(principal, qual)
    if has("thin", "cover", "coverage", "single point", "bottleneck", "bus factor", "depth"):
        return _thin_cover(principal)
    if has("blocked", "not cleared", "cannot work", "can't work", "stopped", "exposure", "tomorrow"):
        return _blocked(principal)
    if has("first time", "first performance", "supervis", "shadow"):
        return _supervision(principal)
    # Corporate compliance training is a different question from OSHA audit
    # readiness, and both mention "compliance". Test the narrower one first.
    if has("compliance training", "training overdue", "overdue on compliance",
           "cyber", "harassment", "code of conduct", "attestation", "sox", "privacy",
           "mandatory training", "annual training"):
        return _compliance_overdue(principal)
    if has("audit", "osha", "ready", "compliant", "compliance", "prove", "inspector"):
        return _audit_ready(principal, site)
    if has("lapse", "expir", "renew", "due"):
        return _renewals(principal)
    if has("transfer", "unplanned", "moved", "outside what", "mid-shift", "midshift"):
        return _transfers(principal)
    if has("manager", "team", "reporting line", "completion", "worst", "best"):
        return _team_completion(principal)
    if has("excel", "development", "elective", "self-enrol", "self-enroll", "upskill course"):
        return _development(principal)

    # Person lookup last: a name match is the weakest signal, so it must not
    # outrank a question that is really about something else.
    m = (re.search(r"([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)'s\s+(?:record|profile|history|training)", q)
         or re.search(r"(?:record|profile|history|show me|about|look up)\s+(?:for\s+)?([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)", q))
    if m:
        return _person_record(principal, m.group(1).strip())
    if site:
        return _audit_ready(principal, site)
    if qual:
        return _opportunity(principal, qual)

    return {
        "answer": "I can answer questions about who is blocked from tomorrow's work, whether a site "
                  "would pass an audit, where cover is thin, who could close a coverage gap, "
                  "a gap, what lapses within ninety days, and where people worked outside what they "
                  "were scheduled for.\n\nEvery answer is limited to what your viewer scope permits.",
        "view": None,
        "rows": [],
        "unmatched": True,
    }


@router.get("/suggestions")
def suggestions():
    return {"suggestions": SUGGESTIONS, "genie_available": genie.enabled()}


def _governed(q: str, principal: str) -> dict:
    result = route(q, principal)
    result["engine"] = "governed"
    result["sources"] = [
        "gate.v_shift_clearance",
        "gate.v_site_roster",
        "gate.v_coverage",
        "gate.v_credential_opportunity",
        "gate.v_renewal_pipeline",
        "gate.v_learning_assignment",
        "gate.v_team_compliance",
    ]
    return result


@router.post("")
def ask(payload: dict = Body(...)):
    q = (payload.get("question") or "").strip()
    principal = payload.get("principal") or config.DEFAULT_PRINCIPAL
    engine = (payload.get("engine") or "governed").lower()
    if not q:
        return {"answer": "Ask a question about qualification, coverage or exposure.", "rows": []}

    # Genie widens the question surface over the same gold tables and returns the
    # SQL it ran. If it is unavailable or errors, the governed intents answer, so
    # the assistant never goes silent.
    if engine == "genie" and genie.enabled():
        try:
            result = genie.ask(q)
        except Exception as exc:  # noqa: BLE001
            result = _governed(q, principal)
            result["genie_error"] = str(exc)
            result["engine"] = "governed"
    else:
        result = _governed(q, principal)

    result["question"] = q
    result["principal"] = principal
    return result
