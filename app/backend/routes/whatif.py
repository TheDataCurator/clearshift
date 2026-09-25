"""What-if studio — build tomorrow's compliant crew.

The online half of the AI decisioning layer. It reads tomorrow's regulated shift
demand and the qualified pool from the same governed views the rest of the app
uses, joins the persisted lapse-risk scores (gate.lapse_risk, written nightly by
model/score_batch.py), and runs the CP-SAT optimizer live to produce a compliant
crew plan.

The unit of assignment is a shift: a person scheduled to a work center must hold
every regulated qualification that work center requires at once. The plan never
violates a hard rule: a worker is only placed on a seat whose full requirement
they currently hold, in scope for that plant; a first-time regulated performance
is paired with a qualified supervisor; nobody is double-booked. Among feasible
plans it prefers workers whose relevant certification is least likely to lapse.
Seats it cannot compliantly staff are returned explicitly, with the reason, so a
supervisor acts before the shift rather than after.
"""

from __future__ import annotations

from datetime import date, timedelta

from fastapi import APIRouter, Body, Query

from backend import config, db
from backend.optimizer import Job, Worker, assign

router = APIRouter(prefix="/api/whatif", tags=["whatif"])

FIRST_PERF_CLEARANCE = "SUPERVISION_REQUIRED"
_SEVERITY = {"NOT_CLEARED": 3, "SUPERVISION_REQUIRED": 2, "CLEARED_EXPIRING": 1, "CLEARED": 0}


def _worst(a: str, b: str) -> str:
    return a if _SEVERITY.get(a, 0) >= _SEVERITY.get(b, 0) else b


def _scenario(principal: str, work_date: date, exclude: set[str]):
    """Assemble optimizer inputs from the governed views.

    Returns (jobs, workers, job_meta, current_counts). A job is one scheduled
    (worker, work center) seat carrying the set of regulated qualifications it
    demands. job_meta carries display detail and the current verdict per seat.
    """
    predicate, params = db.scope_clause(principal)
    params["d"] = work_date

    shift_rows = db.query(
        f"""
        SELECT employee_id AS scheduled_id, employee_name AS scheduled_name,
               location, work_center_id, work_center_desc,
               qualification_id, qualification_name, clearance, reason
          FROM gate.v_shift_clearance
         WHERE work_date = %(d)s AND is_regulated AND {predicate}
         ORDER BY location, work_center_desc
        """,
        params,
    )

    # Collapse requirement rows into one seat per (scheduled worker, work center).
    seats: dict[str, dict] = {}
    plants = set()
    for r in shift_rows:
        job_id = f"{r['work_center_id']}|{r['scheduled_id']}"
        seat = seats.setdefault(job_id, {
            "job_id": job_id,
            "plant": r["location"],
            "work_center": r["work_center_desc"],
            "scheduled_id": r["scheduled_id"],
            "scheduled_name": r["scheduled_name"],
            "required_quals": set(),
            "qualification_names": [],
            "current_clearance": "CLEARED",
            "current_reason": None,
            "first_time_regulated": False,
        })
        seat["required_quals"].add(r["qualification_id"])
        seat["qualification_names"].append(r["qualification_name"])
        if r["clearance"] == FIRST_PERF_CLEARANCE:
            seat["first_time_regulated"] = True
        if _SEVERITY.get(r["clearance"], 0) > _SEVERITY.get(seat["current_clearance"], 0):
            seat["current_clearance"] = r["clearance"]
            seat["current_reason"] = r["reason"]
        plants.add(r["location"])

    jobs, job_meta = [], {}
    for s in seats.values():
        jobs.append(Job(job_id=s["job_id"], plant=s["plant"],
                        required_quals=frozenset(s["required_quals"]),
                        first_time_regulated=s["first_time_regulated"]))
        s["qualification"] = " + ".join(sorted(set(s["qualification_names"])))
        job_meta[s["job_id"]] = s

    current_counts = {"cleared": 0, "exposed": 0, "seats": len(seats)}
    for s in seats.values():
        if s["current_clearance"] in ("NOT_CLEARED", FIRST_PERF_CLEARANCE):
            current_counts["exposed"] += 1
        else:
            current_counts["cleared"] += 1

    if not jobs:
        return jobs, [], job_meta, current_counts

    # Worker pool: everyone at the demanded plants holding a regulated
    # qualification in scope, with what they can supervise and the persisted
    # lapse-risk of each held qualification.
    pool_rows = db.query(
        """
        SELECT qs.employee_id,
               e.name          AS employee_name,
               e.locationname  AS plant,
               qs.qualification_id,
               COALESCE(tm.is_supervisory, false) AS is_supervisory,
               lr.lapse_risk
          FROM gate.v_qualification_state qs
          JOIN gate.hr_employee e ON e.id = qs.employee_id
          LEFT JOIN gate.v_training_matrix tm ON tm.employee_id = qs.employee_id
          LEFT JOIN gate.lapse_risk lr
                 ON lr.employee_id = qs.employee_id
                AND lr.qualification_id = qs.qualification_id
         WHERE qs.is_regulated
           AND qs.state IN ('CURRENT', 'EXPIRING')
           AND e.locationname = ANY(%(plants)s)
        """,
        {"plants": list(plants)},
    )

    demanded = set()
    for j in jobs:
        for q in j.reqs():
            demanded.add((j.plant, q))

    by_worker: dict[str, dict] = {}
    for r in pool_rows:
        w = by_worker.setdefault(r["employee_id"], {
            "employee_name": r["employee_name"], "plant": r["plant"],
            "is_supervisory": r["is_supervisory"], "quals": set(), "risk_by_qual": {},
        })
        w["quals"].add(r["qualification_id"])
        w["risk_by_qual"][r["qualification_id"]] = (
            float(r["lapse_risk"]) if r["lapse_risk"] is not None else 0.5)

    workers = []
    for wid, w in by_worker.items():
        if wid in exclude:
            continue
        relevant = [w["risk_by_qual"][q] for q in w["quals"] if (w["plant"], q) in demanded]
        risk = max(relevant) if relevant else 0.5
        workers.append(Worker(
            worker_id=wid, plant=w["plant"], quals=frozenset(w["quals"]),
            lapse_risk=risk,
            can_supervise=frozenset(w["quals"]) if w["is_supervisory"] else frozenset(),
        ))

    return jobs, workers, job_meta, current_counts


@router.get("/scenario")
def scenario(principal: str = Query(default=None), work_date: date | None = Query(default=None)):
    principal = principal or config.DEFAULT_PRINCIPAL
    d = work_date or (date.today() + timedelta(days=1))
    jobs, workers, job_meta, counts = _scenario(principal, d, set())
    names = {}
    if workers:
        names = {r["id"]: r["name"] for r in db.query(
            "SELECT id, name FROM gate.hr_employee WHERE id = ANY(%(ids)s)",
            {"ids": [w.worker_id for w in workers]})}
    return {
        "principal": principal, "work_date": d,
        "seat_count": len(jobs), "worker_count": len(workers), "current": counts,
        "seats": list(job_meta.values()),
        "workers": sorted(
            [{"employee_id": w.worker_id, "employee_name": names.get(w.worker_id, w.worker_id),
              "qualifications": sorted(w.quals), "lapse_risk": round(w.lapse_risk, 2),
              "can_supervise": bool(w.can_supervise)} for w in workers],
            key=lambda x: x["lapse_risk"], reverse=True),
    }


@router.post("/solve")
def solve(payload: dict = Body(default={})):
    """Run the optimizer and return the plan, the exposure it clears, and what it cannot."""
    principal = payload.get("principal") or config.DEFAULT_PRINCIPAL
    work_date = payload.get("work_date")
    d = date.fromisoformat(work_date) if work_date else (date.today() + timedelta(days=1))
    exclude = set(payload.get("exclude_workers") or [])
    risk_weight = int(payload.get("risk_weight") or 1000)

    jobs, workers, job_meta, counts = _scenario(principal, d, exclude)
    if not jobs:
        return {"principal": principal, "work_date": d, "status": "NO_JOBS",
                "message": "No regulated shift demand in scope for this date.",
                "current": counts, "assignments": [], "uncovered": []}

    names = {r["id"]: r["name"] for r in db.query(
        "SELECT id, name FROM gate.hr_employee WHERE id = ANY(%(ids)s)",
        {"ids": [w.worker_id for w in workers]})} if workers else {}

    result = assign(jobs, workers, risk_weight=risk_weight)

    assignments, exposure_cleared = [], 0
    for a in result["assignments"]:
        meta = job_meta[a["job"]]
        reassigned = a["worker"] != meta["scheduled_id"]
        if meta["current_clearance"] in ("NOT_CLEARED", FIRST_PERF_CLEARANCE):
            exposure_cleared += 1
        assignments.append({
            "job_id": meta["job_id"], "plant": meta["plant"], "work_center": meta["work_center"],
            "qualification": meta["qualification"], "first_time_regulated": meta["first_time_regulated"],
            "scheduled_id": meta["scheduled_id"], "scheduled_name": meta["scheduled_name"],
            "current_clearance": meta["current_clearance"],
            "assigned_id": a["worker"], "assigned_name": names.get(a["worker"], a["worker"]),
            "assigned_lapse_risk": a["lapse_risk"], "reassigned_from_scheduled": reassigned,
        })

    # Reason each uncovered seat, against the full qualified pool.
    def holds_full(job) -> bool:
        return any(w.plant == job.plant and job.reqs() <= w.quals for w in workers)

    def has_supervisor(job) -> bool:
        return any(w.plant == job.plant and (w.can_supervise & job.reqs()) for w in workers)

    jobs_by_id = {j.job_id: j for j in jobs}
    uncovered = []
    for job_id in result["uncovered"]:
        meta = job_meta[job_id]
        job = jobs_by_id[job_id]
        if not holds_full(job):
            reason = (f"No worker holds the full requirement ({meta['qualification']}) "
                      f"for {meta['work_center']} at {meta['plant']}.")
        elif meta["first_time_regulated"] and not has_supervisor(job):
            reason = (f"First-time regulated work needs a qualified supervisor present; "
                      f"none available at {meta['plant']}.")
        else:
            reason = "Qualified capacity is fully committed to other regulated seats this shift."
        uncovered.append({
            "job_id": job_id, "plant": meta["plant"], "work_center": meta["work_center"],
            "qualification": meta["qualification"], "scheduled_name": meta["scheduled_name"],
            "current_clearance": meta["current_clearance"], "reason": reason,
        })

    total_risk = round(sum(a["assigned_lapse_risk"] for a in assignments), 2)
    return {
        "principal": principal, "work_date": d, "status": result["status"], "current": counts,
        "summary": {
            "seats": len(jobs), "covered": len(assignments), "uncovered": len(uncovered),
            "exposure_cleared": exposure_cleared, "total_assigned_lapse_risk": total_risk,
        },
        "assignments": sorted(assignments,
                              key=lambda x: (not x["reassigned_from_scheduled"], x["work_center"])),
        "uncovered": uncovered,
        "note": ("Scores are the persisted output of the lapse-risk model (gate.lapse_risk). "
                 "The plan is solved live with CP-SAT; hard compliance rules are constraints, "
                 "never traded off."),
    }
