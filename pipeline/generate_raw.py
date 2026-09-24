"""Generate synthetic raw source files for the ClearShift medallion pipeline.

Customer-safe by construction: fictional Meridian Manufacturing, generic
plant cities, no real people. The data is engineered so the gold clearance
layer produces every verdict (CLEARED, NOT_CLEARED, SUPERVISION_REQUIRED,
CLEARED_EXPIRING, OUT_OF_SCOPE) and so the lapse-risk feature table has signal.

Emits one folder of CSV files per source entity under pipeline/raw/, which the
bronze layer ingests with Auto Loader (read_files). Run: python3 generate_raw.py
"""

from __future__ import annotations

import csv
import datetime as dt
import os

TODAY = dt.date(2026, 9, 23)
RAW = os.path.join(os.path.dirname(__file__), "raw")


def d(days: int) -> str:
    """A date offset from TODAY, as ISO text."""
    return (TODAY + dt.timedelta(days=days)).isoformat()


def write(entity: str, rows: list[dict]) -> None:
    """Write one raw CSV file into its own folder (Auto Loader ingests folders)."""
    folder = os.path.join(RAW, entity)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{entity}.csv")
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"  {entity:38s} {len(rows):3d} rows -> {os.path.relpath(path)}")


# ---------------------------------------------------------------------------
# Reference: qualifications that gate work (OSHA-anchored)
# ---------------------------------------------------------------------------
qualification = [
    dict(qualification_id="LOTO", name="Lockout/Tagout Authorized",
         is_regulated="true", regulation_reference="29 CFR 1910.147",
         requires_supervised_first_performance="false", scope="PORTABLE",
         validity_months="12", renewal_warning_days="60"),
    dict(qualification_id="CONFINED", name="Confined Space Entrant",
         is_regulated="true", regulation_reference="29 CFR 1910.146",
         requires_supervised_first_performance="true", scope="SITE_SPECIFIC",
         validity_months="12", renewal_warning_days="60"),
    dict(qualification_id="HOTWORK", name="Hot Work / Welding Permit",
         is_regulated="true", regulation_reference="29 CFR 1910.252",
         requires_supervised_first_performance="true", scope="PORTABLE",
         validity_months="12", renewal_warning_days="45"),
    dict(qualification_id="PSM", name="Process Safety Management Qualified",
         is_regulated="true", regulation_reference="29 CFR 1910.119",
         requires_supervised_first_performance="false", scope="PORTABLE",
         validity_months="24", renewal_warning_days="90"),
    dict(qualification_id="FORKLIFT", name="Powered Industrial Truck Operator",
         is_regulated="true", regulation_reference="29 CFR 1910.178",
         requires_supervised_first_performance="false", scope="PORTABLE",
         validity_months="36", renewal_warning_days="60"),
]

# Work centers and what they demand. Join key is the work center code.
workcenter_requirement = [
    dict(work_center_id="WC_TANK",    qualification_id="CONFINED", effective_from=d(-1000), effective_to=""),
    dict(work_center_id="WC_TANK",    qualification_id="HOTWORK",  effective_from=d(-1000), effective_to=""),
    dict(work_center_id="WC_LINE1",   qualification_id="LOTO",     effective_from=d(-1000), effective_to=""),
    dict(work_center_id="WC_DOCK",    qualification_id="FORKLIFT", effective_from=d(-1000), effective_to=""),
    dict(work_center_id="WC_REACTOR", qualification_id="PSM",      effective_from=d(-1000), effective_to=""),
    dict(work_center_id="WC_REACTOR", qualification_id="LOTO",     effective_from=d(-1000), effective_to=""),
]

# Requirements that travel with the job title (matches hr_employee.descr).
job_requirement = [
    dict(job_description="Welder", qualification_id="HOTWORK", effective_from=d(-1000), effective_to=""),
]

# ---------------------------------------------------------------------------
# Workforce (HCM). Two Meridian plants.
# ---------------------------------------------------------------------------
PEIL = "Peoria IL - Plant 3081"
GRMI = "Grand Rapids MI - Plant 2401"


def emp(id, name, descr, loc, supvid, supvname, dept="Operations"):
    return dict(id=id, name=name, email=f"{id.lower()}@meridianmfg.example",
                regregion="US", company="MM", companyname="Meridian Manufacturing",
                servicelinecode="OPS", servicelinename="Operations",
                location=loc[:4], locationname=loc, deptid="D1", deptname=dept,
                supvid=supvid, supvname=supvname, orgunitleader=supvname,
                descr=descr, subfunction="Plant", careerlevel="P2",
                careerleveldescription="Skilled Trade", labortype="DIRECT",
                grade="G4", type="FT", paystatus="A", regtemp="R", fullpart="F",
                jobentrydate=d(-1500), lateststartdate=d(-1500), datelastincrease=d(-200),
                annualrt="72000", monthlyrt="6000", hrlyrate="34.6",
                city=loc.split(" - ")[0][:-3], state=loc.split(" - ")[0][-2:],
                postal="00000", gender="U", birthdate="1990-01-01", marstatus="U",
                militarystatus="U", filename="hcm_extract")


hr_employee = [
    emp("E100", "Dana Whitlock",  "Shift Supervisor", PEIL, "E100", "Dana Whitlock"),
    emp("E101", "Ray Okafor",     "Operator",         PEIL, "E100", "Dana Whitlock"),
    emp("E102", "Mia Sandoval",   "Welder",           PEIL, "E100", "Dana Whitlock"),
    emp("E103", "Theo Brandt",    "Operator",         PEIL, "E100", "Dana Whitlock"),
    emp("E104", "Lena Park",      "Operator",         PEIL, "E100", "Dana Whitlock"),
    emp("E200", "Cole Ferreira",  "Plant Manager",    GRMI, "E200", "Cole Ferreira"),
    emp("E201", "Nadia Rees",     "Welder",           GRMI, "E200", "Cole Ferreira"),
    emp("E202", "Sam Ihejirika",  "Operator",         GRMI, "E200", "Cole Ferreira"),
]

# What each person holds. Engineered to hit each clearance verdict.
employee_qualification = [
    # E101 fully current: CLEARED on WC_LINE1 (LOTO)
    dict(employee_id="E101", qualification_id="LOTO", issued_on=d(-120), expires_on=d(245), revoked_on="", revoked_reason="", scoped_to="", evidence_reference="cert:E101-LOTO"),
    # E102 welder: HOTWORK current, CONFINED site-scoped to PEIL (in scope), first performance pending -> SUPERVISION_REQUIRED
    dict(employee_id="E102", qualification_id="HOTWORK",  issued_on=d(-90),  expires_on=d(275), revoked_on="", revoked_reason="", scoped_to="", evidence_reference="cert:E102-HW"),
    dict(employee_id="E102", qualification_id="CONFINED", issued_on=d(-30),  expires_on=d(335), revoked_on="", revoked_reason="", scoped_to=PEIL, evidence_reference="cert:E102-CS"),
    # E103 LOTO expiring within warning window -> CLEARED_EXPIRING
    dict(employee_id="E103", qualification_id="LOTO", issued_on=d(-350), expires_on=d(20), revoked_on="", revoked_reason="", scoped_to="", evidence_reference="cert:E103-LOTO"),
    # E104 LOTO expired -> NOT_CLEARED
    dict(employee_id="E104", qualification_id="LOTO", issued_on=d(-400), expires_on=d(-35), revoked_on="", revoked_reason="", scoped_to="", evidence_reference="cert:E104-LOTO"),
    # E201 (GRMI welder) CONFINED scoped to PEIL, but works GRMI -> OUT_OF_SCOPE; HOTWORK current
    dict(employee_id="E201", qualification_id="HOTWORK",  issued_on=d(-60), expires_on=d(305), revoked_on="", revoked_reason="", scoped_to="", evidence_reference="cert:E201-HW"),
    dict(employee_id="E201", qualification_id="CONFINED", issued_on=d(-45), expires_on=d(320), revoked_on="", revoked_reason="", scoped_to=PEIL, evidence_reference="cert:E201-CS"),
    # E202 FORKLIFT current -> CLEARED on WC_DOCK
    dict(employee_id="E202", qualification_id="FORKLIFT", issued_on=d(-200), expires_on=d(895), revoked_on="", revoked_reason="", scoped_to="", evidence_reference="cert:E202-FL"),
    # E100 supervisor holds PSM + LOTO current
    dict(employee_id="E100", qualification_id="PSM",  issued_on=d(-300), expires_on=d(430), revoked_on="", revoked_reason="", scoped_to="", evidence_reference="cert:E100-PSM"),
    dict(employee_id="E100", qualification_id="LOTO", issued_on=d(-100), expires_on=d(265), revoked_on="", revoked_reason="", scoped_to="", evidence_reference="cert:E100-LOTO"),
    # E101 also holds an expired CONFINED (prior lapse -> signal for the model)
    dict(employee_id="E101", qualification_id="CONFINED", issued_on=d(-800), expires_on=d(-420), revoked_on="", revoked_reason="", scoped_to=PEIL, evidence_reference="cert:E101-CS-old"),
]

# Forward schedule (what work each person is assigned to, past and future).
def sched(emp_id, day_offset, wc_code, wc_desc, actual_code=None, status="SCHEDULED"):
    actual = actual_code or (wc_code if status != "SCHEDULED" else "")
    return dict(employee_id=emp_id, work_date=d(day_offset),
                scheduled_wc_code=wc_code, scheduled_wc_value=wc_code, scheduled_wc_desc=wc_desc,
                actual_wc_code=actual, actual_wc_value=actual,
                actual_wc_desc=(wc_desc if actual else ""),
                scheduled_segment_count="1", scheduled_total_seconds="28800", scheduled_hours="8",
                worked_span_count=("1" if actual else "0"),
                worked_total_seconds=("28800" if actual else "0"),
                worked_hours=("8" if actual else "0"), variance_hours="0",
                wc_count_on_date="1", has_transfer_on_date="false", assignment_status=status)


employee_scheduled_workcenter_history = [
    # Tomorrow's scheduled shifts (the clearance question)
    sched("E101", 1, "WC_LINE1",   "Line 1 Assembly"),
    sched("E102", 1, "WC_TANK",    "Tank Entry / Weld"),      # first-time confined -> SUPERVISION_REQUIRED
    sched("E103", 1, "WC_LINE1",   "Line 1 Assembly"),        # expiring -> CLEARED_EXPIRING
    sched("E104", 1, "WC_LINE1",   "Line 1 Assembly"),        # expired -> NOT_CLEARED
    sched("E201", 1, "WC_TANK",    "Tank Entry / Weld"),      # confined out-of-scope -> NOT_CLEARED
    sched("E202", 1, "WC_DOCK",    "Shipping Dock"),          # forklift current -> CLEARED
    sched("E100", 1, "WC_REACTOR", "Reactor House"),          # PSM+LOTO current -> CLEARED
    # An unplanned transfer in the recent past (E104 moved into WC_LINE1 while lapsed)
    sched("E104", -3, "WC_DOCK", "Shipping Dock", actual_code="WC_LINE1", status="WORKED"),
    # Prior worked days that establish experience for E102 HOTWORK (so only CONFINED is first-time)
    sched("E102", -20, "WC_TANK", "Tank Entry / Weld", actual_code="WC_TANK", status="WORKED"),
]
# Fix the -3 transfer row so actual desc differs
for r in employee_scheduled_workcenter_history:
    if r["employee_id"] == "E104" and r["work_date"] == d(-3):
        r["actual_wc_desc"] = "Line 1 Assembly"
        r["has_transfer_on_date"] = "true"

employee_current_workcenter_assignment = [
    dict(employee_id="E101", work_center_id="WC_LINE1",   work_center_desc="Line 1 Assembly", work_center_source="UKG", effective_date=d(-10)),
    dict(employee_id="E102", work_center_id="WC_TANK",    work_center_desc="Tank Entry / Weld", work_center_source="UKG", effective_date=d(-10)),
    dict(employee_id="E103", work_center_id="WC_LINE1",   work_center_desc="Line 1 Assembly", work_center_source="UKG", effective_date=d(-10)),
    dict(employee_id="E104", work_center_id="WC_LINE1",   work_center_desc="Line 1 Assembly", work_center_source="UKG", effective_date=d(-10)),
    dict(employee_id="E201", work_center_id="WC_TANK",    work_center_desc="Tank Entry / Weld", work_center_source="UKG", effective_date=d(-10)),
    dict(employee_id="E202", work_center_id="WC_DOCK",    work_center_desc="Shipping Dock", work_center_source="UKG", effective_date=d(-10)),
    dict(employee_id="E100", work_center_id="WC_REACTOR", work_center_desc="Reactor House", work_center_source="UKG", effective_date=d(-10)),
]

# Supervised-first-performance ledger (E102 confined entry is open/pending)
first_performance = [
    dict(first_performance_id="1", employee_id="E102", qualification_id="CONFINED",
         work_center_id="WC_TANK", work_date=d(1), status="PENDING",
         supervised_by="", supervised_on="", waived_by="", waiver_reason=""),
]

# Training pipeline (renewal signal)
training_session = [
    dict(session_id="1", qualification_id="LOTO", title="LOTO Recertification",
         audience="PLANT", delivery="IN_PERSON", site_id="PEIL", starts_on=d(10),
         seats="12", instructor="D. Whitlock"),
]
training_enrolment = [
    dict(enrolment_id="1", session_id="1", employee_id="E104", status="ENROLLED"),
    dict(enrolment_id="2", session_id="1", employee_id="E103", status="WAITLIST"),
]

# Recordable incidents (safety outcome / TRIR inputs)
recordable_incident = [
    dict(recordable_incident_id="1", case_number="MM-2026-014", employee_id="E104",
         site_id="PEIL", incident_on=d(-3), work_center_id="WC_LINE1",
         classification="RESTRICTED_TRANSFER", days_away="0", days_restricted="4",
         description="Minor injury during unplanned transfer while LOTO lapsed"),
]

if __name__ == "__main__":
    print(f"Generating ClearShift raw source files (as of {TODAY.isoformat()}) into {RAW}/")
    write("qualification", qualification)
    write("workcenter_requirement", workcenter_requirement)
    write("job_requirement", job_requirement)
    write("hr_employee", hr_employee)
    write("employee_qualification", employee_qualification)
    write("employee_scheduled_workcenter_history", employee_scheduled_workcenter_history)
    write("employee_current_workcenter_assignment", employee_current_workcenter_assignment)
    write("first_performance", first_performance)
    write("training_session", training_session)
    write("training_enrolment", training_enrolment)
    write("recordable_incident", recordable_incident)
    print("Done.")
