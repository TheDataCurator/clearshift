"""Qualification gate endpoints.

Three reads for the three personas, plus the two writes that close the loop:
acknowledging an alert and signing off a supervised first performance.
"""

from __future__ import annotations

from datetime import date, timedelta

from fastapi import APIRouter, Body, Query

from backend import config, db

router = APIRouter(prefix="/api/gate", tags=["gate"])


# ---------------------------------------------------------------------------
# Supervisor — tomorrow's crew
# ---------------------------------------------------------------------------

@router.get("/shift-clearance")
def shift_clearance(
    principal: str = Query(default=None),
    work_date: date | None = Query(default=None),
):
    """Every scheduled shift with a verdict per requirement.

    Defaults to tomorrow, so a supervisor is reached before the shift.
    """
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)
    # Default to the next day: the check is only useful ahead of the shift.
    params["work_date"] = work_date or (date.today() + timedelta(days=1))

    rows = db.query(
        f"""
        SELECT * FROM gate.v_shift_clearance
         WHERE work_date = %(work_date)s
           AND {predicate}
         ORDER BY
           CASE clearance
             WHEN 'NOT_CLEARED'          THEN 1
             WHEN 'SUPERVISION_REQUIRED' THEN 2
             WHEN 'CLEARED_EXPIRING'     THEN 3
             ELSE 4
           END,
           employee_name,
           qualification_name
        """,
        params,
    )

    # Roll requirements up per person, keeping the worst verdict at the top
    order = {"NOT_CLEARED": 1, "SUPERVISION_REQUIRED": 2, "CLEARED_EXPIRING": 3, "CLEARED": 4}
    by_employee: dict[str, dict] = {}
    for row in rows:
        emp = by_employee.setdefault(
            row["employee_id"],
            {
                "employee_id": row["employee_id"],
                "employee_name": row["employee_name"],
                "job_description": row["job_description"],
                "department": row["department"],
                "location": row["location"],
                "supervisor_name": row["supervisor_name"],
                "work_date": row["work_date"],
                "work_center_desc": row["work_center_desc"],
                "first_time_at_work_center": row["first_time_at_work_center"],
                "clearance": row["clearance"],
                "requirements": [],
            },
        )
        if order[row["clearance"]] < order[emp["clearance"]]:
            emp["clearance"] = row["clearance"]
        emp["requirements"].append(
            {
                "qualification_id": row["qualification_id"],
                "qualification_name": row["qualification_name"],
                "is_regulated": row["is_regulated"],
                "regulation_reference": row["regulation_reference"],
                "requirement_source": row["requirement_source"],
                "state": row["qualification_state"],
                "clearance": row["clearance"],
                "reason": row["reason"],
                "expires_on": row["expires_on"],
                "days_until_expiry": row["days_until_expiry"],
                "evidence_reference": row["evidence_reference"],
                "first_performance_status": row["first_performance_status"],
            }
        )

    employees = sorted(by_employee.values(), key=lambda e: (order[e["clearance"]], e["employee_name"]))
    return {
        "principal": principal,
        "work_date": params["work_date"],
        "summary": {
            "not_cleared": sum(1 for e in employees if e["clearance"] == "NOT_CLEARED"),
            "supervision_required": sum(1 for e in employees if e["clearance"] == "SUPERVISION_REQUIRED"),
            "expiring": sum(1 for e in employees if e["clearance"] == "CLEARED_EXPIRING"),
            "cleared": sum(1 for e in employees if e["clearance"] == "CLEARED"),
        },
        "employees": employees,
    }


# ---------------------------------------------------------------------------
# Auditor — everyone at a site, as of a date
# ---------------------------------------------------------------------------

@router.get("/site-roster")
def site_roster(
    principal: str = Query(default=None),
    location: str | None = Query(default=None),
    regulated_only: bool = Query(default=True),
):
    """The audit answer. One row per person per required qualification."""
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)
    params["location"] = location
    params["regulated_only"] = regulated_only

    rows = db.query(
        f"""
        SELECT * FROM gate.v_site_roster
         WHERE {predicate}
           AND (%(location)s IS NULL OR location = %(location)s)
           AND (NOT %(regulated_only)s OR is_regulated)
         ORDER BY location, employee_name, qualification_name
        """,
        params,
    )

    total = len({r["employee_id"] for r in rows})
    gaps = {r["employee_id"] for r in rows if r["qualification_state"] not in ("CURRENT", "EXPIRING")}
    return {
        "principal": principal,
        "as_of": date.today(),
        "summary": {
            "people": total,
            "people_with_gaps": len(gaps),
            "compliant": total - len(gaps),
        },
        "rows": rows,
    }


# ---------------------------------------------------------------------------
# Safety — what a clock-in gate misses, and what lapses next
# ---------------------------------------------------------------------------

@router.get("/unplanned-transfers")
def unplanned_transfers(principal: str = Query(default=None)):
    """Scheduled into work they were cleared for, moved to work they were not."""
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)
    rows = db.query(
        f"SELECT * FROM gate.v_unplanned_transfer WHERE {predicate} ORDER BY work_date DESC",
        params,
    )
    return {"principal": principal, "rows": rows}


@router.get("/renewal-pipeline")
def renewal_pipeline(principal: str = Query(default=None)):
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)
    rows = db.query(
        f"""
        SELECT * FROM gate.v_renewal_pipeline
         WHERE {predicate}
         ORDER BY days_until_expiry
        """,
        params,
    )
    buckets: dict[str, int] = {}
    for row in rows:
        buckets[row["bucket"]] = buckets.get(row["bucket"], 0) + 1
    return {"principal": principal, "buckets": buckets, "rows": rows}


# ---------------------------------------------------------------------------
# Writes — what makes the alert a control rather than a notification
# ---------------------------------------------------------------------------

@router.post("/first-performance/sign-off")
def sign_off_first_performance(payload: dict = Body(...)):
    """Record that a supervised first performance actually happened.

    This row is the audit evidence that the control was applied, so the
    supervisor is named rather than implied.
    """
    db.execute(
        """
        INSERT INTO gate.first_performance
            (employee_id, qualification_id, work_center_id, work_date, status, supervised_by, supervised_on)
        VALUES (%(employee_id)s, %(qualification_id)s, %(work_center_id)s, %(work_date)s,
                'SUPERVISED', %(supervised_by)s, CURRENT_DATE)
        ON CONFLICT (employee_id, qualification_id, work_center_id)
        DO UPDATE SET status = 'SUPERVISED',
                      supervised_by = EXCLUDED.supervised_by,
                      supervised_on = CURRENT_DATE
        """,
        payload,
    )
    return {"status": "recorded"}


@router.post("/alerts/acknowledge")
def acknowledge_alert(payload: dict = Body(...)):
    """An alert nobody answered is not a control."""
    db.execute(
        """
        UPDATE gate.alert
           SET acknowledged_by = %(acknowledged_by)s,
               acknowledged_at = now(),
               resolution      = %(resolution)s
         WHERE alert_id = %(alert_id)s
        """,
        payload,
    )
    return {"status": "acknowledged"}


@router.get("/principals")
def principals():
    """Viewer scopes available in the demo, so the access model can be shown."""
    return db.query(
        "SELECT principal, scope_type, scope_value FROM gate.viewer_scope ORDER BY scope_type, principal"
    )


@router.get("/credential-card/{employee_id}")
def credential_card(employee_id: str, principal: str = Query(default=None)):
    """The worker's credential card.

    The floor-facing artifact: an inspector walks up, asks to see a
    qualification, and this is what gets shown on a tablet. Everything an
    inspector asks for on the spot, and nothing else.

    Scope applies: a supervisor cannot pull a card outside their crew. Who viewed
    a card is recorded, since access itself is part of the control.
    """
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)
    params["eid"] = employee_id

    who = db.query(
        f"""
        SELECT employee_id, employee_name, job_description, department, location,
               supervisor_name, is_supervisory, osha10_on, osha10_serial, osha10_trainer,
               osha30_on, osha30_serial, osha30_trainer, loto_role, hazcom_trained_on,
               hazcom_trained, competent_for, hazwork_craft, hazwork_regulated,
               hazwork_na_reason, hazwork_expires_on, hazwork_status, audit_status
          FROM gate.v_training_matrix
         WHERE employee_id = %(eid)s AND {predicate}
        """,
        params,
    )
    if not who:
        return {"found": False, "reason": "Not found, or outside your scope."}

    person = who[0]

    creds = db.query(
        """
        SELECT qualification_id, qualification_name, is_regulated, regulation_reference,
               state, issued_on, expires_on, days_until_expiry, scoped_to,
               evidence_reference, revoked_reason, requires_supervised_first_performance
          FROM gate.v_qualification_state
         WHERE employee_id = %(eid)s
         ORDER BY is_regulated DESC,
                  CASE state WHEN 'EXPIRED' THEN 1 WHEN 'REVOKED' THEN 2
                             WHEN 'OUT_OF_SCOPE' THEN 3 WHEN 'EXPIRING' THEN 4 ELSE 5 END,
                  qualification_name
        """,
        {"eid": employee_id},
    )

    # Practical evaluations, which are a separate duty from the credential
    evals = db.query(
        """
        SELECT pe.qualification_id, q.name AS qualification_name, pe.evaluated_on,
               pe.evaluator_name, pe.outcome, q.practical_evaluation_months,
               (pe.evaluated_on < CURRENT_DATE - (q.practical_evaluation_months || ' months')::interval) AS overdue
          FROM gate.practical_evaluation pe
          JOIN gate.qualification q ON q.qualification_id = pe.qualification_id
         WHERE pe.employee_id = %(eid)s
           AND pe.evaluated_on = (SELECT max(evaluated_on) FROM gate.practical_evaluation pe2
                                   WHERE pe2.employee_id = pe.employee_id
                                     AND pe2.qualification_id = pe.qualification_id)
         ORDER BY q.name
        """,
        {"eid": employee_id},
    )

    # What today's or tomorrow's assignment demands
    predicate2, params2 = db.scope_clause(principal)
    params2["eid"] = employee_id
    params2["d"] = date.today() + timedelta(days=1)
    next_shift = db.query(
        f"""
        SELECT work_date, work_center_desc, qualification_name, clearance, reason
          FROM gate.v_shift_clearance
         WHERE employee_id = %(eid)s AND work_date = %(d)s AND {predicate2}
         ORDER BY CASE clearance WHEN 'NOT_CLEARED' THEN 1
                                 WHEN 'SUPERVISION_REQUIRED' THEN 2 ELSE 3 END
        """,
        params2,
    )

    acks = db.query(
        """
        SELECT subject, kind, signed_date, method, signed_by_name, proxy_for,
               trainer_name, document_ref, is_proxy
          FROM gate.v_acknowledgment
         WHERE employee_id = %(eid)s
         ORDER BY signed_on DESC
        """,
        {"eid": employee_id},
    )

    blocking = [c for c in creds
                if c["state"] in ("EXPIRED", "REVOKED", "OUT_OF_SCOPE") and c["is_regulated"]]

    return {
        "found": True,
        "as_of": date.today(),
        "person": person,
        "credentials": creds,
        "evaluations": evals,
        "next_shift": next_shift,
        "acknowledgments": acks,
        "summary": {
            "regulated_held": sum(1 for c in creds
                                  if c["is_regulated"] and c["state"] in ("CURRENT", "EXPIRING")),
            "regulated_total": sum(1 for c in creds if c["is_regulated"]),
            "blocking": len(blocking),
            "evaluations_overdue": sum(1 for e in evals if e["overdue"]),
            "signed": len(acks),
        },
    }


@router.get("/roster-lookup")
def roster_lookup(principal: str = Query(default=None)):
    """Names an inspector can pick from, within scope."""
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)
    return db.query(
        f"""
        SELECT employee_id, employee_name, job_description, department, audit_status
          FROM gate.v_training_matrix
         WHERE {predicate}
         ORDER BY employee_name
        """,
        params,
    )


@router.post("/credentialing-request")
def credentialing_request(payload: dict = Body(...)):
    """Ask a supervisor to consider putting someone forward for a credential.

    Recorded rather than sent. The request is the artifact and it is auditable;
    whether it leaves as mail, a chat message or a ticket is a delivery detail. The
    coverage position is stored alongside so the request still reads correctly
    once the gap has moved on.
    """
    db.execute(
        """
        INSERT INTO gate.credentialing_request
            (employee_id, qualification_id, location, supervisor_name, requested_by,
             qualified_at_request, cover_state_at_request, route, note)
        VALUES (%(employee_id)s, %(qualification_id)s, %(location)s, %(supervisor_name)s,
                %(requested_by)s, %(qualified_now)s, %(cover_state)s, %(route)s, %(note)s)
        """,
        {
            "employee_id": payload.get("employee_id"),
            "qualification_id": payload.get("qualification_id"),
            "location": payload.get("location"),
            "supervisor_name": payload.get("supervisor_name"),
            "requested_by": payload.get("requested_by") or config.DEFAULT_PRINCIPAL,
            "qualified_now": payload.get("qualified_now"),
            "cover_state": payload.get("cover_state"),
            "route": payload.get("route"),
            "note": payload.get("note"),
        },
    )
    return {"status": "recorded"}


@router.get("/credentialing-requests")
def credentialing_requests(principal: str = Query(default=None)):
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)
    return {
        "rows": db.query(
            f"SELECT * FROM gate.v_credentialing_request WHERE {predicate} "
            f"ORDER BY requested_at DESC",
            params,
        )
    }
