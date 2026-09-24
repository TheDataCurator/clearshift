"""
ClearShift compliant crew-assignment optimizer (CP-SAT / OR-Tools).

Given scheduled hazardous jobs, a worker pool with current in-scope
qualifications, and per-worker lapse-risk scores from the model, assign workers
to jobs so that:

HARD constraints:
  - a worker may only be assigned to a job whose required qualification they
    currently hold, in scope for that job's plant;
  - a first performance of a regulated task must be paired with a qualified
    supervisor also assigned at that plant;
  - a worker is assigned to at most one job in the horizon (no double-booking).

OBJECTIVE (lexicographic via weights):
  1. cover as many scheduled jobs as possible;
  2. among covered jobs, prefer lower-risk workers (minimize total assigned
     lapse-risk), so scarce low-risk capacity is spent where it matters.

Jobs that cannot be compliantly covered are reported explicitly.

This module is decision logic, not ML. It consumes the model's risk scores.
Run directly to see it solve a small synthetic scenario.
"""

from dataclasses import dataclass, field
from typing import Optional

from ortools.sat.python import cp_model


@dataclass(frozen=True)
class Job:
    job_id: str
    plant: str
    qualification: str
    first_time_regulated: bool = False  # needs a supervisor if a first performance


@dataclass(frozen=True)
class Worker:
    worker_id: str
    plant: str
    quals: frozenset          # qualifications held, current and in scope for `plant`
    lapse_risk: float         # 0..1 from the model
    can_supervise: frozenset = field(default_factory=frozenset)  # quals they can supervise


def assign(jobs, workers, risk_weight: int = 1000):
    m = cp_model.CpModel()

    # x[j, w] = worker w assigned to job j (only where eligible)
    x = {}
    for j in jobs:
        for w in workers:
            if w.plant == j.plant and j.qualification in w.quals:
                x[(j.job_id, w.worker_id)] = m.NewBoolVar(f"x_{j.job_id}_{w.worker_id}")

    covered = {j.job_id: m.NewBoolVar(f"covered_{j.job_id}") for j in jobs}

    # each job filled by at most one worker; covered iff someone is assigned
    for j in jobs:
        cands = [x[(j.job_id, w.worker_id)] for w in workers
                 if (j.job_id, w.worker_id) in x]
        if cands:
            m.Add(sum(cands) == covered[j.job_id])
        else:
            m.Add(covered[j.job_id] == 0)  # nobody eligible: cannot cover

    # no double-booking: a worker takes at most one job
    for w in workers:
        w_vars = [x[(j.job_id, w.worker_id)] for j in jobs
                  if (j.job_id, w.worker_id) in x]
        if w_vars:
            m.Add(sum(w_vars) <= 1)

    # supervisor rule: a covered first-time regulated job needs a qualified
    # supervisor present at the plant who is not the performer.
    for j in jobs:
        if not j.first_time_regulated:
            continue
        sup_terms = []
        for w in workers:
            if w.plant == j.plant and j.qualification in w.can_supervise:
                s = m.NewBoolVar(f"sup_{j.job_id}_{w.worker_id}")
                # supervisor cannot also be the performer of the same job
                if (j.job_id, w.worker_id) in x:
                    m.Add(s + x[(j.job_id, w.worker_id)] <= 1)
                sup_terms.append(s)
                m.Add(sum(sw for jj in jobs
                          for sw in [s] if jj.job_id == j.job_id) <= 1)
        # if covered, at least one supervisor must be present
        if sup_terms:
            m.Add(sum(sup_terms) >= covered[j.job_id])
        else:
            m.Add(covered[j.job_id] == 0)  # no eligible supervisor: cannot cover

    # objective: maximize coverage first, then prefer low-risk assignments
    risk_terms = []
    for (job_id, worker_id), var in x.items():
        w = next(w for w in workers if w.worker_id == worker_id)
        risk_terms.append(int(round(w.lapse_risk * 100)) * var)
    m.Maximize(risk_weight * sum(covered.values()) - sum(risk_terms))

    solver = cp_model.CpSolver()
    status = solver.Solve(m)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return {"status": solver.StatusName(status), "assignments": [], "uncovered": [j.job_id for j in jobs]}

    assignments, uncovered = [], []
    for j in jobs:
        who = [w for w in workers if (j.job_id, w.worker_id) in x
               and solver.Value(x[(j.job_id, w.worker_id)]) == 1]
        if who:
            assignments.append({"job": j.job_id, "plant": j.plant,
                                "qualification": j.qualification,
                                "worker": who[0].worker_id,
                                "lapse_risk": round(who[0].lapse_risk, 2)})
        else:
            uncovered.append(j.job_id)
    return {"status": solver.StatusName(status),
            "assignments": assignments, "uncovered": uncovered}


def _demo():
    jobs = [
        Job("J1", "Peoria", "LOTO"),
        Job("J2", "Peoria", "CONFINED", first_time_regulated=True),
        Job("J3", "Peoria", "PIT"),
        Job("J4", "GrandRapids", "HOTWORK"),   # no eligible worker -> uncovered
    ]
    workers = [
        Worker("W1", "Peoria", frozenset({"LOTO", "PIT"}), 0.72,
               can_supervise=frozenset({"CONFINED"})),
        Worker("W2", "Peoria", frozenset({"LOTO"}), 0.15),
        Worker("W3", "Peoria", frozenset({"CONFINED"}), 0.40),
        Worker("W4", "Peoria", frozenset({"PIT"}), 0.30),
    ]
    result = assign(jobs, workers)
    print(f"solver status: {result['status']}")
    print("assignments:")
    for a in result["assignments"]:
        print(f"    {a['job']} @ {a['plant']} ({a['qualification']}) -> {a['worker']}  risk={a['lapse_risk']}")
    print(f"uncovered (cannot compliantly staff): {result['uncovered']}")


if __name__ == "__main__":
    _demo()
