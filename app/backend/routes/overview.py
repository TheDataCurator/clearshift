"""Executive overview.

Network readiness, coverage depth, and where one additional credential would
relieve a thin spot.
"""

from __future__ import annotations

from datetime import date, timedelta

from fastapi import APIRouter, Query

from backend import config, db

router = APIRouter(prefix="/api/overview", tags=["overview"])


@router.get("")
def overview(principal: str = Query(default=None)):
    principal = principal or config.DEFAULT_PRINCIPAL

    sites = db.query(
        """
        SELECT site_id, label, city, state, latitude, longitude, site_type,
               rollout_status, rollout_on, headcount_estimate,
               people_assessed, people_covered, people_with_gap, expiring_90,
               coverage_pct, readiness
          FROM gate.v_site_readiness
         ORDER BY rollout_on NULLS FIRST, label
        """
    )

    # Program shape. Sites not yet onboarded are reported as unknown rather
    # than folded into a coverage figure, because a site with no data is not the
    # same as a site with no gaps.
    onboarded = [s for s in sites if s["people_assessed"]]
    assessed = sum(s["people_assessed"] or 0 for s in onboarded)
    covered = sum(s["people_covered"] or 0 for s in onboarded)
    gaps = sum(s["people_with_gap"] or 0 for s in onboarded)

    coverage = db.query(
        """
        SELECT location, qualification_id, qualification_name, qualified_now, cover_state
          FROM gate.v_coverage
         WHERE is_regulated
         ORDER BY qualified_now, qualification_name
        """
    )

    # Blocked shifts tomorrow, across every site in the principal's scope
    predicate, params = db.scope_clause(principal)
    params["work_date"] = date.today() + timedelta(days=1)
    blocked = db.query(
        f"""
        SELECT count(DISTINCT employee_id) AS n
          FROM gate.v_shift_clearance
         WHERE work_date = %(work_date)s
           AND clearance = 'NOT_CLEARED'
           AND {predicate}
        """,
        params,
    )

    supervision = db.query(
        f"""
        SELECT count(DISTINCT employee_id) AS n
          FROM gate.v_shift_clearance
         WHERE work_date = %(work_date)s
           AND clearance = 'SUPERVISION_REQUIRED'
           AND {predicate}
        """,
        params,
    )

    return {
        "principal": principal,
        "as_of": date.today(),
        "program": {
            "sites_total": len(sites),
            "sites_live": sum(1 for s in sites if s["rollout_status"] == "LIVE"),
            "sites_in_flight": sum(1 for s in sites if s["rollout_status"] == "IN_FLIGHT"),
            "sites_planned": sum(1 for s in sites if s["rollout_status"] == "PLANNED"),
            "sites_onboarded": len(onboarded),
            "workforce_estimate": sum(s["headcount_estimate"] or 0 for s in sites),
            "people_assessed": assessed,
            "people_covered": covered,
            "people_with_gap": gaps,
            "coverage_pct": round(100.0 * covered / assessed) if assessed else None,
            "blocked_tomorrow": blocked[0]["n"] if blocked else 0,
            "supervision_tomorrow": supervision[0]["n"] if supervision else 0,
        },
        "sites": sites,
        "coverage": coverage,
        "no_cover": [c for c in coverage if c["cover_state"] == "NO_COVER"],
        "single_point": [c for c in coverage if c["cover_state"] == "SINGLE_POINT"],
    }


@router.get("/credential-opportunity")
def credential_opportunity(
    location: str | None = Query(default=None),
    qualification_id: str | None = Query(default=None),
    limit: int = Query(default=3, ge=1, le=10),
):
    """Where one additional credential would relieve a coverage gap.

    Returns the thin credentials at each site with the best-placed internal
    candidates, so the question "must we hire" can be answered before it is asked.
    """
    rows = db.query(
        """
        SELECT * FROM gate.v_credential_opportunity
         WHERE (%(location)s IS NULL OR location = %(location)s)
           AND (%(qualification_id)s IS NULL OR qualification_id = %(qualification_id)s)
         ORDER BY location, qualification_name, readiness_score DESC
        """,
        {"location": location, "qualification_id": qualification_id},
    )

    # Group by the gap, keeping only the strongest few candidates for each
    gapped: dict[tuple[str, str], dict] = {}
    for r in rows:
        key = (r["location"], r["qualification_id"])
        g = gapped.setdefault(
            key,
            {
                "location": r["location"],
                "qualification_id": r["qualification_id"],
                "qualification_name": r["qualification_name"],
                "qualified_now": r["qualified_now"],
                "cover_state": r["cover_state"],
                "candidates": [],
            },
        )
        if len(g["candidates"]) < limit:
            g["candidates"].append(
                {
                    "employee_id": r["employee_id"],
                    "employee_name": r["employee_name"],
                    "job_description": r["job_description"],
                    "department": r["department"],
                    "supervisor_name": r["supervisor_name"],
                    "credentials_held": r["credentials_held"],
                    "already_assigned_to_such_work": r["already_assigned_to_such_work"],
                    "previously_revoked": r["previously_revoked"],
                    "revoked_reason": r["revoked_reason"],
                    "lapsed_only": r["lapsed_only"],
                    "route": r["route"],
                    "readiness_score": r["readiness_score"],
                }
            )

    order = {"NO_COVER": 0, "SINGLE_POINT": 1, "THIN": 2}
    gaps = sorted(gapped.values(), key=lambda g: (order.get(g["cover_state"], 9), g["location"]))
    return {"gaps": gaps}


@router.get("/training")
def training():
    """Scheduled sessions, plant and office alike.

    Sessions that close a live gap are marked, because a coordinator's time is
    better spent on those than on ones that merely add depth.
    """
    rows = db.query(
        """
        SELECT session_id, title, qualification_id, qualification_name, is_regulated,
               audience, delivery, site_label, location, starts_on, days_away,
               seats, instructor, enrolled, would_close_gaps, relieves_thin_cover
          FROM gate.v_upcoming_training
        """
    )
    return {
        "as_of": date.today(),
        "summary": {
            "sessions": len(rows),
            "plant": sum(1 for r in rows if r["audience"] in ("PLANT", "ALL")),
            "office": sum(1 for r in rows if r["audience"] in ("OFFICE", "ALL")),
            "closing_gaps": sum(1 for r in rows if r["would_close_gaps"]),
            "next_30": sum(1 for r in rows if r["days_away"] <= 30),
        },
        "rows": rows,
    }


@router.get("/audit")
def audit(
    principal: str = Query(default=None),
    location: str | None = Query(default=None),
):
    """Internal audit and inspection readiness.

    Two modes off one payload. The internal view leads with findings, ordered by
    how a citation would land. The inspection view leads with the roster, because
    an inspector picks names from it and expects each to resolve to evidence.
    """
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)
    params["location"] = location

    matrix = db.query(
        f"""
        SELECT * FROM gate.v_training_matrix
         WHERE {predicate} AND (%(location)s IS NULL OR location = %(location)s)
         ORDER BY CASE audit_status
                    WHEN 'GAP' THEN 1 WHEN 'EVALUATION_OVERDUE' THEN 2
                    WHEN 'SUPERVISOR_NO_30HR' THEN 3 WHEN 'NO_OUTREACH_CARD' THEN 4 ELSE 5 END,
                  employee_name
        """,
        params,
    )

    # Findings carry no supervisor on site-level rows, so crew scope would drop
    # them entirely. Scope by location for this read.
    loc_pred, loc_params = db.scope_clause(principal)
    findings = db.query(
        """
        SELECT * FROM gate.v_audit_finding
         WHERE (%(location)s IS NULL OR location = %(location)s)
         ORDER BY severity_rank, finding_type, employee_name NULLS LAST
        """,
        {"location": location},
    )
    visible_locs = {m["location"] for m in matrix}
    findings = [f for f in findings if f["location"] in visible_locs]

    incidents = db.query(
        """
        SELECT * FROM gate.v_incident_review
         WHERE (%(location)s IS NULL OR location = %(location)s)
         ORDER BY incident_on DESC
        """,
        {"location": location},
    )
    incidents = [i for i in incidents if i["location"] in visible_locs]

    programs = db.query(
        """
        SELECT w.name, w.standard_ref, w.version, w.last_reviewed_on, w.review_months,
               w.owner_name, w.document_ref, s.locationname AS location,
               (w.last_reviewed_on < CURRENT_DATE - (w.review_months || ' months')::interval) AS overdue
          FROM gate.written_program w
          LEFT JOIN gate.site s ON s.site_id = w.site_id
         ORDER BY overdue DESC, w.name
        """
    )
    programs = [p for p in programs if p["location"] in visible_locs or p["location"] is None]

    checklist = db.query(
        """
        SELECT * FROM gate.v_site_checklist
         WHERE (%(location)s IS NULL OR location = %(location)s)
        """,
        {"location": location},
    )
    checklist = [c for c in checklist if c["location"] in visible_locs]

    acks = db.query(
        f"""
        SELECT * FROM gate.v_acknowledgment
         WHERE {predicate} AND (%(location)s IS NULL OR location = %(location)s)
         ORDER BY signed_on DESC
         LIMIT 60
        """,
        params,
    )

    missing_acks = db.query(
        f"""
        SELECT * FROM gate.v_missing_acknowledgment
         WHERE {predicate}
         ORDER BY employee_name, qualification_name
        """,
        {k: v for k, v in params.items() if k != "location"},
    )

    return {
        "principal": principal,
        "as_of": date.today(),
        "summary": {
            "workers": len(matrix),
            "checks_failed": sum(1 for c in checklist if c["status"] == "FAIL"),
            "checks_total": sum(1 for c in checklist if c["status"] != "NOT_CHECKED"),
            "hazwork_in_scope": sum(1 for m in matrix if m["hazwork_regulated"]),
            "hazwork_issues": sum(1 for m in matrix if m["hazwork_regulated"]
                              and m["hazwork_status"] in ("EXPIRED", "OVERSIGHT_OVERDUE", "NOT_QUALIFIED")),
            "complete": sum(1 for m in matrix if m["audit_status"] == "COMPLETE"),
            "findings": len(findings),
            "critical": sum(1 for f in findings if f["severity_rank"] == 1),
            "programs_overdue": sum(1 for p in programs if p["overdue"]),
            "recordables": len(incidents),
            "acknowledgments": len(acks),
            "acknowledgments_proxy": sum(1 for a in acks if a["is_proxy"]),
            "acknowledgments_missing": len(missing_acks),
            "recordables_unqualified": sum(1 for i in incidents if i["unheld_at_time"]),
        },
        "matrix": matrix,
        "checklist": checklist,
        "acknowledgments": acks,
        "missing_acknowledgments": missing_acks,
        "findings": findings,
        "incidents": incidents,
        "programs": programs,
    }


@router.get("/learning")
def learning(principal: str = Query(default=None)):
    """Corporate learning.

    Same spine as the plant side, different resolver. A plant requirement is
    triggered by the work center and blocks assignment; a corporate obligation is
    triggered by role or department and carries a due date. Both are read here.
    """
    principal = principal or config.DEFAULT_PRINCIPAL
    predicate, params = db.scope_clause(principal)

    rows = db.query(
        f"""
        SELECT * FROM gate.v_learning_assignment
         WHERE {predicate}
         ORDER BY CASE status
                    WHEN 'OVERDUE' THEN 1 WHEN 'DUE_SOON' THEN 2
                    WHEN 'IN_PROGRESS' THEN 3 WHEN 'ON_TRACK' THEN 4 ELSE 5 END,
                  employee_name, title
        """,
        params,
    )

    teams = db.query(
        f"""
        SELECT * FROM gate.v_team_compliance
         WHERE {predicate}
         ORDER BY compliance_overdue DESC, supervisor_name
        """,
        params,
    )

    policies = db.query("SELECT * FROM gate.v_policy_status ORDER BY category, title")

    compliance = [r for r in rows if r["category"] == "COMPLIANCE"]
    development = [r for r in rows if r["category"] == "DEVELOPMENT"]

    return {
        "principal": principal,
        "as_of": date.today(),
        "summary": {
            "people": len({r["employee_id"] for r in rows}),
            "compliance_assigned": len(compliance),
            "compliance_complete": sum(1 for r in compliance if r["status"] == "COMPLETE"),
            "overdue": sum(1 for r in compliance if r["status"] == "OVERDUE"),
            "due_soon": sum(1 for r in compliance if r["status"] == "DUE_SOON"),
            "development_active": sum(1 for r in development if r["status"] == "IN_PROGRESS"),
            "people_developing": len({r["employee_id"] for r in development}),
            "compliance_pct": round(
                100.0 * sum(1 for r in compliance if r["status"] == "COMPLETE") / len(compliance)
            ) if compliance else None,
        },
        "rows": rows,
        "teams": teams,
        "policies": policies,
    }


@router.get("/glossary")
def glossary():
    """Credentials, the standards behind them, and the words people use for them.

    The everyday word and the regulatory name often share nothing, so the mapping
    is shown rather than left implicit in the matching logic.
    """
    return {
        "as_of": date.today(),
        "rows": db.query("SELECT * FROM gate.v_glossary"),
        "terms": db.query(
            """
            SELECT t.qualification_id, q.name AS qualification_name, t.term, t.kind
              FROM gate.terminology t
              JOIN gate.qualification q ON q.qualification_id = t.qualification_id
             ORDER BY q.name, t.kind, t.term
            """
        ),
    }


@router.get("/trend")
def trend(principal: str = Query(default=None)):
    """Direction rather than level: is exposure shrinking, is it caught earlier.

    Three readings are kept apart because collapsing them misleads:

      - Network coverage falls when a site onboards, because a plant's worth of
        unassessed people joins the denominator. Same-site coverage is reported
        alongside so that reads as progress rather than regression.
      - Supervised first performances are a success count and may rise. The number
        that should fall is first performances that went ahead unsupervised.
      - Falling exposure is ambiguous unless volume is visible: the gate working
        and the schedule feed stopping look the same. Scheduled shifts travel with
        the exposure series.
    """
    principal = principal or config.DEFAULT_PRINCIPAL

    network = db.query("SELECT * FROM gate.v_trend_network")
    by_site = db.query("SELECT * FROM gate.v_trend_weekly WHERE was_onboarded")

    # Derived from the source tables alone, which is the point worth making: the
    # history did not have to be accumulated.
    derived = db.query("SELECT * FROM gate.v_trend_derived")

    first, last = (network[0], network[-1]) if network else (None, None)

    def delta(key):
        if not first or not last or first.get(key) is None or last.get(key) is None:
            return None
        return round(float(last[key]) - float(first[key]), 1)

    return {
        "principal": principal,
        "as_of": date.today(),
        "network": network,
        "by_site": by_site,
        "derived": derived,
        "summary": {
            "weeks": len(network),
            "blocked_per_100_first": first["blocked_per_100_shifts"] if first else None,
            "blocked_per_100_last": last["blocked_per_100_shifts"] if last else None,
            "blocked_per_100_delta": delta("blocked_per_100_shifts"),
            "unsupervised_last": last["unsupervised_first_performance"] if last else None,
            "coverage_last": last["coverage_pct"] if last else None,
            "baseline_coverage_last": last["baseline_coverage_pct"] if last else None,
            "days_to_close_first": first["median_days_to_close"] if first else None,
            "days_to_close_last": last["median_days_to_close"] if last else None,
            "sites_onboarded": last["sites_onboarded"] if last else None,
        },
    }
