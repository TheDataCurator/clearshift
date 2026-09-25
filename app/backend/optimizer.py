"""
ClearShift compliant crew-assignment optimizer (CP-SAT / OR-Tools).

Given the scheduled hazardous shifts, a worker pool with current in-scope
qualifications, and per-worker lapse-risk scores from the model, assign workers
to shifts so that:

HARD constraints:
  - a worker may only be assigned to a shift whose full set of required
    qualifications they currently hold, in scope for that shift's plant;
  - a shift containing a first-time regulated task must be paired with a
    qualified supervisor also assigned at that plant, who is not the performer;
  - a worker is assigned to at most one shift in the horizon (no double-booking).

OBJECTIVE (lexicographic via weights):
  1. cover as many scheduled shifts as possible;
  2. among covered shifts, prefer lower-risk workers (minimize total assigned
     lapse-risk), so scarce low-risk capacity is spent where it matters.

Shifts that cannot be compliantly covered are reported explicitly.

A shift is the unit of assignment because a person scheduled to a work center
must hold every qualification that work center requires at once; modelling each
requirement as a separate job would let the plan put two people on one seat.

This module is decision logic, not ML. It consumes the model's risk scores.
Run directly to see it solve a small synthetic scenario.
"""

from dataclasses import dataclass, field

from ortools.sat.python import cp_model


@dataclass(frozen=True)
class Job:
    """A shift to staff. `required_quals` is the full set the seat demands; the
    single `qualification` field is a convenience for one-qualification shifts."""
    job_id: str
    plant: str
    qualification: str = ""
    required_quals: frozenset = field(default_factory=frozenset)
    first_time_regulated: bool = False  # needs a supervisor if a first performance

    def reqs(self) -> frozenset:
        return self.required_quals or (frozenset({self.qualification}) if self.qualification else frozenset())


@dataclass(frozen=True)
class Worker:
    worker_id: str
    plant: str
    quals: frozenset          # qualifications held, current and in scope for `plant`
    lapse_risk: float         # 0..1 from the model
    can_supervise: frozenset = field(default_factory=frozenset)  # quals they can supervise


def _eligible(w: Worker, j: Job) -> bool:
    return w.plant == j.plant and j.reqs() <= w.quals


def assign(jobs, workers, risk_weight: int = 1000):
    m = cp_model.CpModel()

    # x[j, w] = worker w assigned to shift j (only where eligible)
    x = {}
    for j in jobs:
        for w in workers:
            if _eligible(w, j):
                x[(j.job_id, w.worker_id)] = m.NewBoolVar(f"x_{j.job_id}_{w.worker_id}")

    covered = {j.job_id: m.NewBoolVar(f"covered_{j.job_id}") for j in jobs}

    # each shift filled by at most one worker; covered iff someone is assigned
    for j in jobs:
        cands = [x[(j.job_id, w.worker_id)] for w in workers
                 if (j.job_id, w.worker_id) in x]
        if cands:
            m.Add(sum(cands) == covered[j.job_id])
        else:
            m.Add(covered[j.job_id] == 0)  # nobody eligible: cannot cover

    # supervisor rule: a covered first-time regulated shift needs one qualified
    # supervisor present at the plant. A supervisor qualifies if they can
    # supervise at least one of the shift's requirements. Supervision is a named
    # assignment, not a free boolean, so a supervisor cannot cover two shifts at
    # once and cannot also be performing elsewhere.
    sup = {}
    for j in jobs:
        if not j.first_time_regulated:
            continue
        for w in workers:
            if w.plant == j.plant and (w.can_supervise & j.reqs()):
                sup[(j.job_id, w.worker_id)] = m.NewBoolVar(f"sup_{j.job_id}_{w.worker_id}")

    for j in jobs:
        if not j.first_time_regulated:
            continue
        sterms = [sup[(j.job_id, w.worker_id)] for w in workers
                  if (j.job_id, w.worker_id) in sup]
        if sterms:
            # exactly one supervisor when the shift is covered, none otherwise
            m.Add(sum(sterms) == covered[j.job_id])
        else:
            m.Add(covered[j.job_id] == 0)  # no eligible supervisor: cannot cover

    # no double-booking: a worker takes at most one commitment in the horizon,
    # whether performing a shift or supervising one. This is what stops a single
    # supervisor from being counted on two first-time shifts at the same time.
    for w in workers:
        commits = [x[k] for k in x if k[1] == w.worker_id] \
                + [sup[k] for k in sup if k[1] == w.worker_id]
        if commits:
            m.Add(sum(commits) <= 1)

    # objective: maximize coverage first, then prefer low-risk assignments
    risk = {w.worker_id: int(round(w.lapse_risk * 100)) for w in workers}
    risk_terms = [risk[worker_id] * var for (job_id, worker_id), var in x.items()]
    m.Maximize(risk_weight * sum(covered.values()) - sum(risk_terms))

    solver = cp_model.CpSolver()
    status = solver.Solve(m)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return {"status": solver.StatusName(status), "assignments": [],
                "uncovered": [j.job_id for j in jobs]}

    by_id = {w.worker_id: w for w in workers}
    assignments, uncovered = [], []
    for j in jobs:
        who = [w for w in workers if (j.job_id, w.worker_id) in x
               and solver.Value(x[(j.job_id, w.worker_id)]) == 1]
        if who:
            assignments.append({"job": j.job_id, "plant": j.plant,
                                "qualification": j.qualification,
                                "qualifications": sorted(j.reqs()),
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
        print(f"    {a['job']} @ {a['plant']} ({'+'.join(a['qualifications'])}) "
              f"-> {a['worker']}  risk={a['lapse_risk']}")
    print(f"uncovered (cannot compliantly staff): {result['uncovered']}")


if __name__ == "__main__":
    _demo()
