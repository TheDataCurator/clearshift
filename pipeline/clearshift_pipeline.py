"""ClearShift medallion pipeline (Lakeflow Declarative Pipelines / DLT).

Bronze ingests the synthetic raw source files with Auto Loader. Silver types,
deduplicates and quality-checks them. Gold reimplements the ClearShift clearance
logic (faithful to the Postgres views in lakebase/ddl/03_views.sql and the
compliance/coverage views) as governed tables, and adds a feature table for the
lapse-risk model.

Target namespace comes from pipeline configuration, not hardcoded:
  clearshift.raw_path    filesystem path holding the raw/ folders
  catalog / target       set on the pipeline (catalog=clearshift, schema per layer)

The clearance verdicts match the app: CLEARED, CLEARED_EXPIRING,
SUPERVISION_REQUIRED, NOT_CLEARED, with a plain-language reason.
"""

import dlt
from pyspark.sql import functions as F

RAW_PATH = spark.conf.get("clearshift.raw_path", "/Volumes/clearshift/raw/landing")


# ===========================================================================
# BRONZE - raw ingestion with Auto Loader (one streaming table per source)
# ===========================================================================

def _bronze(entity: str, fmt: str = "csv"):
    """Register a bronze streaming table that tails a raw source folder."""

    @dlt.table(name=f"bronze_{entity}", comment=f"Raw {entity}, ingested as landed.")
    def _ingest():
        return (
            spark.readStream.format("cloudFiles")
            .option("cloudFiles.format", fmt)
            .option("header", "true")
            .option("cloudFiles.schemaLocation", f"{RAW_PATH}/_schema/{entity}")
            .option("cloudFiles.inferColumnTypes", "true")
            .load(f"{RAW_PATH}/{entity}")
            .withColumn("_ingested_at", F.current_timestamp())
            .withColumn("_source_file", F.col("_metadata.file_path"))
        )

    return _ingest


for _e in [
    "qualification", "workcenter_requirement", "job_requirement", "hr_employee",
    "employee_qualification", "employee_scheduled_workcenter_history",
    "employee_current_workcenter_assignment", "first_performance",
    "training_session", "training_enrolment", "recordable_incident",
]:
    _bronze(_e)


# ===========================================================================
# SILVER - typed, deduplicated, quality-checked
# ===========================================================================

@dlt.table(comment="Qualifications that gate work, typed.")
@dlt.expect_or_drop("has_id", "qualification_id IS NOT NULL")
def silver_qualification():
    return (
        dlt.read("bronze_qualification")
        .select(
            "qualification_id", "name",
            F.col("is_regulated").cast("boolean").alias("is_regulated"),
            "regulation_reference",
            F.col("requires_supervised_first_performance").cast("boolean")
             .alias("requires_supervised_first_performance"),
            "scope",
            F.col("validity_months").cast("int").alias("validity_months"),
            F.col("renewal_warning_days").cast("int").alias("renewal_warning_days"),
        )
        .dropDuplicates(["qualification_id"])
    )


@dlt.table(comment="Active workforce (HCM), one row per employee.")
@dlt.expect_or_drop("has_id", "id IS NOT NULL")
@dlt.expect("active_paystatus", "paystatus = 'A'")
def silver_hr_employee():
    return (
        dlt.read("bronze_hr_employee")
        .select("id", "name", "email", "locationname", "deptname",
                "descr", "supvid", "supvname", "paystatus", "city", "state")
        .dropDuplicates(["id"])
    )


@dlt.table(comment="What each work center demands, effective-dated.")
def silver_workcenter_requirement():
    return (
        dlt.read("bronze_workcenter_requirement")
        .withColumn("effective_from", F.to_date("effective_from"))
        .withColumn("effective_to", F.to_date(F.nullif(F.col("effective_to"), F.lit(""))))
        .dropDuplicates(["work_center_id", "qualification_id", "effective_from"])
    )


@dlt.table(comment="Requirements that travel with the job title.")
def silver_job_requirement():
    return (
        dlt.read("bronze_job_requirement")
        .withColumn("effective_from", F.to_date("effective_from"))
        .withColumn("effective_to", F.to_date(F.nullif(F.col("effective_to"), F.lit(""))))
        .dropDuplicates(["job_description", "qualification_id", "effective_from"])
    )


@dlt.table(comment="What each person holds, temporal.")
@dlt.expect_or_drop("valid_window", "expires_on IS NULL OR expires_on > issued_on")
def silver_employee_qualification():
    return (
        dlt.read("bronze_employee_qualification")
        .withColumn("issued_on", F.to_date("issued_on"))
        .withColumn("expires_on", F.to_date(F.nullif(F.col("expires_on"), F.lit(""))))
        .withColumn("revoked_on", F.to_date(F.nullif(F.col("revoked_on"), F.lit(""))))
        .withColumn("scoped_to", F.nullif(F.col("scoped_to"), F.lit("")))
        .dropDuplicates(["employee_id", "qualification_id", "issued_on"])
    )


@dlt.table(comment="Scheduled and actual work center history (UKG).")
@dlt.expect_or_drop("has_date", "work_date IS NOT NULL")
def silver_schedule_history():
    return (
        dlt.read("bronze_employee_scheduled_workcenter_history")
        .withColumn("work_date", F.to_date("work_date"))
        .withColumn("scheduled_wc_code", F.col("scheduled_wc_code"))
        .withColumn("actual_wc_code", F.nullif(F.col("actual_wc_code"), F.lit("")))
        .withColumn("actual_wc_desc", F.nullif(F.col("actual_wc_desc"), F.lit("")))
        .withColumn("variance_hours", F.col("variance_hours").cast("double"))
        .withColumn("wc_count_on_date", F.col("wc_count_on_date").cast("int"))
    )


@dlt.table(comment="Current work center assignment (UKG).")
def silver_current_assignment():
    return (
        dlt.read("bronze_employee_current_workcenter_assignment")
        .dropDuplicates(["employee_id"])
    )


@dlt.table(comment="Supervised first-performance ledger.")
def silver_first_performance():
    return (
        dlt.read("bronze_first_performance")
        .withColumn("work_date", F.to_date("work_date"))
        .withColumn("supervised_on", F.to_date(F.nullif(F.col("supervised_on"), F.lit(""))))
    )


@dlt.table(comment="Recordable incidents (TRIR / DART inputs).")
def silver_recordable_incident():
    return (
        dlt.read("bronze_recordable_incident")
        .withColumn("incident_on", F.to_date("incident_on"))
        .withColumn("days_away", F.col("days_away").cast("int"))
        .withColumn("days_restricted", F.col("days_restricted").cast("int"))
    )


@dlt.table(comment="Training sessions.")
def silver_training_session():
    return dlt.read("bronze_training_session").withColumn("starts_on", F.to_date("starts_on"))


@dlt.table(comment="Training enrolments.")
def silver_training_enrolment():
    return dlt.read("bronze_training_enrolment")


# ===========================================================================
# GOLD - the ClearShift logic, faithful to lakebase/ddl/03_views.sql
# Complex temporal joins are expressed in Spark SQL over the LIVE (pipeline)
# schema so they read like the original views.
# ===========================================================================

@dlt.table(comment="Whether a person held a qualification as of today, with state.")
def gold_qualification_state():
    return spark.sql("""
        SELECT
            eq.employee_id, eq.qualification_id, q.name AS qualification_name,
            q.is_regulated, q.regulation_reference,
            q.requires_supervised_first_performance, q.scope, q.renewal_warning_days,
            eq.issued_on, eq.expires_on, eq.revoked_on, eq.revoked_reason,
            eq.scoped_to, eq.evidence_reference, e.locationname AS employee_location,
            CASE
                WHEN eq.revoked_on IS NOT NULL AND eq.revoked_on <= current_date() THEN 'REVOKED'
                WHEN eq.expires_on IS NOT NULL AND eq.expires_on <  current_date() THEN 'EXPIRED'
                WHEN q.scope IN ('SITE_SPECIFIC','ASSET_SPECIFIC')
                     AND eq.scoped_to IS NOT NULL
                     AND eq.scoped_to <> e.locationname THEN 'OUT_OF_SCOPE'
                WHEN eq.expires_on IS NOT NULL
                     AND eq.expires_on <= date_add(current_date(), q.renewal_warning_days) THEN 'EXPIRING'
                ELSE 'CURRENT'
            END AS state,
            CASE WHEN eq.expires_on IS NOT NULL
                 THEN datediff(eq.expires_on, current_date()) END AS days_until_expiry
        FROM LIVE.silver_employee_qualification eq
        JOIN LIVE.silver_qualification q ON q.qualification_id = eq.qualification_id
        JOIN LIVE.silver_hr_employee   e ON e.id = eq.employee_id
    """)


@dlt.table(comment="What each scheduled shift requires (work center + job), collapsed.")
def gold_requirement_for_shift():
    return spark.sql("""
        WITH sources AS (
            SELECT h.employee_id, h.work_date, h.scheduled_wc_code AS work_center_id,
                   h.scheduled_wc_desc AS work_center_desc, r.qualification_id,
                   'WORK_CENTER' AS requirement_source
            FROM LIVE.silver_schedule_history h
            JOIN LIVE.silver_workcenter_requirement r
              ON r.work_center_id = h.scheduled_wc_code
             AND r.effective_from <= h.work_date
             AND (r.effective_to IS NULL OR r.effective_to > h.work_date)
            UNION ALL
            SELECT h.employee_id, h.work_date, h.scheduled_wc_code, h.scheduled_wc_desc,
                   j.qualification_id, 'JOB'
            FROM LIVE.silver_schedule_history h
            JOIN LIVE.silver_hr_employee e ON e.id = h.employee_id
            JOIN LIVE.silver_job_requirement j
              ON j.job_description = e.descr
             AND j.effective_from <= h.work_date
             AND (j.effective_to IS NULL OR j.effective_to > h.work_date)
        )
        SELECT employee_id, work_date, work_center_id, work_center_desc, qualification_id,
               concat_ws('+', array_sort(collect_set(requirement_source))) AS requirement_source
        FROM sources
        GROUP BY employee_id, work_date, work_center_id, work_center_desc, qualification_id
    """)


@dlt.table(comment="Shift clearance: every scheduled requirement resolved to a verdict with reason.")
def gold_shift_clearance():
    return spark.sql("""
        WITH worked AS (
            SELECT employee_id, work_date,
                   COALESCE(actual_wc_code, scheduled_wc_code) AS work_center_id
            FROM LIVE.silver_schedule_history
            WHERE assignment_status <> 'SCHEDULED'
        ),
        exercised AS (
            SELECT DISTINCT w.employee_id, w.work_date, wr.qualification_id,
                   e.locationname AS location
            FROM worked w
            JOIN LIVE.silver_workcenter_requirement wr
              ON wr.work_center_id = w.work_center_id
             AND wr.effective_from <= w.work_date
             AND (wr.effective_to IS NULL OR wr.effective_to > w.work_date)
            JOIN LIVE.silver_hr_employee e ON e.id = w.employee_id
            JOIN LIVE.silver_employee_qualification eq
              ON eq.employee_id = w.employee_id
             AND eq.qualification_id = wr.qualification_id
             AND eq.issued_on <= w.work_date
             AND (eq.expires_on IS NULL OR eq.expires_on > w.work_date)
             AND (eq.revoked_on IS NULL OR eq.revoked_on > w.work_date)
        ),
        req AS (
            SELECT r.employee_id, r.work_date, r.work_center_id, r.work_center_desc,
                   r.qualification_id, r.requirement_source,
                   NOT EXISTS (
                       SELECT 1 FROM worked w
                       WHERE w.employee_id = r.employee_id
                         AND w.work_center_id = r.work_center_id
                         AND w.work_date < r.work_date
                   ) AS first_time_at_work_center,
                   NOT EXISTS (
                       SELECT 1 FROM exercised x
                       JOIN LIVE.silver_qualification qq ON qq.qualification_id = r.qualification_id
                       WHERE x.employee_id = r.employee_id
                         AND x.qualification_id = r.qualification_id
                         AND x.work_date < r.work_date
                         AND (qq.scope = 'PORTABLE' OR x.location = e2.locationname)
                   ) AS first_time_performing
            FROM LIVE.gold_requirement_for_shift r
            JOIN LIVE.silver_hr_employee e2 ON e2.id = r.employee_id
        )
        SELECT
            req.employee_id, e.name AS employee_name, e.descr AS job_description,
            e.deptname AS department, e.locationname AS location,
            e.supvid AS supervisor_id, e.supvname AS supervisor_name,
            req.work_date, req.work_center_id, req.work_center_desc, req.qualification_id,
            COALESCE(qs.qualification_name, q.name) AS qualification_name,
            COALESCE(qs.is_regulated, q.is_regulated) AS is_regulated,
            COALESCE(qs.regulation_reference, q.regulation_reference) AS regulation_reference,
            req.requirement_source, req.first_time_at_work_center, req.first_time_performing,
            COALESCE(qs.state, 'MISSING') AS qualification_state,
            qs.expires_on, qs.days_until_expiry, qs.revoked_reason, qs.scoped_to,
            qs.evidence_reference, fp.status AS first_performance_status, fp.supervised_by,
            CASE
                WHEN qs.state IS NULL THEN 'NOT_CLEARED'
                WHEN qs.state IN ('EXPIRED','REVOKED','OUT_OF_SCOPE') THEN 'NOT_CLEARED'
                WHEN COALESCE(qs.requires_supervised_first_performance, false)
                     AND req.first_time_performing
                     AND COALESCE(fp.status,'PENDING') = 'PENDING' THEN 'SUPERVISION_REQUIRED'
                WHEN qs.state = 'EXPIRING' THEN 'CLEARED_EXPIRING'
                ELSE 'CLEARED'
            END AS clearance,
            CASE
                WHEN qs.state IS NULL
                    THEN concat('No record of ', COALESCE(q.name, req.qualification_id))
                WHEN qs.state = 'EXPIRED'
                    THEN concat(qs.qualification_name, ' lapsed ',
                                datediff(current_date(), qs.expires_on), ' days ago')
                WHEN qs.state = 'REVOKED'
                    THEN concat(qs.qualification_name, ' revoked: ',
                                COALESCE(qs.revoked_reason, 'no reason recorded'))
                WHEN qs.state = 'OUT_OF_SCOPE'
                    THEN concat(qs.qualification_name, ' is authorized for ',
                                COALESCE(qs.scoped_to, 'another site'), ', not ', e.locationname)
                WHEN COALESCE(qs.requires_supervised_first_performance, false)
                     AND req.first_time_performing
                     AND COALESCE(fp.status,'PENDING') = 'PENDING'
                    THEN concat('First time performing ', qs.qualification_name, ', in ',
                                req.work_center_desc, '. Supervised performance required.')
                WHEN qs.state = 'EXPIRING'
                    THEN concat(qs.qualification_name, ' expires in ', qs.days_until_expiry, ' days')
                ELSE 'Current'
            END AS reason
        FROM req
        JOIN LIVE.silver_hr_employee e ON e.id = req.employee_id
        LEFT JOIN LIVE.silver_qualification q ON q.qualification_id = req.qualification_id
        LEFT JOIN LIVE.gold_qualification_state qs
               ON qs.employee_id = req.employee_id AND qs.qualification_id = req.qualification_id
        LEFT JOIN LIVE.silver_first_performance fp
               ON fp.employee_id = req.employee_id
              AND fp.qualification_id = req.qualification_id
              AND fp.work_center_id = req.work_center_id
    """)


@dlt.table(comment="Per-site coverage rollup: scheduled vs cleared for the horizon.")
def gold_site_coverage():
    return spark.sql("""
        SELECT
            location,
            count(DISTINCT employee_id) AS scheduled_workers,
            count(DISTINCT CASE WHEN clearance IN ('CLEARED','CLEARED_EXPIRING')
                                THEN employee_id END) AS cleared_workers,
            count(DISTINCT CASE WHEN clearance = 'NOT_CLEARED' THEN employee_id END) AS blocked_workers,
            count(DISTINCT CASE WHEN clearance = 'SUPERVISION_REQUIRED'
                                THEN employee_id END) AS supervision_required_workers,
            round(100.0 * count(DISTINCT CASE WHEN clearance IN ('CLEARED','CLEARED_EXPIRING')
                                THEN employee_id END)
                  / nullif(count(DISTINCT employee_id), 0), 1) AS coverage_pct
        FROM LIVE.gold_shift_clearance
        GROUP BY location
    """)


@dlt.table(comment="First-time-hazardous: scheduled work that is a genuine first performance.")
def gold_first_time_hazardous():
    return spark.sql("""
        SELECT employee_id, employee_name, location, supervisor_name, work_date,
               work_center_desc, qualification_name, regulation_reference,
               first_performance_status, clearance, reason
        FROM LIVE.gold_shift_clearance
        WHERE first_time_performing = true
          AND is_regulated = true
    """)


@dlt.table(comment="Renewal / lapse pipeline: what expires and when.")
def gold_renewal_pipeline():
    return spark.sql("""
        SELECT
            qs.employee_id, e.name AS employee_name, e.locationname AS location,
            e.deptname AS department, e.supvname AS supervisor_name,
            qs.qualification_id, qs.qualification_name, qs.is_regulated,
            qs.expires_on, qs.days_until_expiry,
            CASE
                WHEN qs.days_until_expiry < 0  THEN 'LAPSED'
                WHEN qs.days_until_expiry <= 30 THEN 'DUE_30'
                WHEN qs.days_until_expiry <= 60 THEN 'DUE_60'
                ELSE 'DUE_90'
            END AS bucket
        FROM LIVE.gold_qualification_state qs
        JOIN LIVE.silver_hr_employee e ON e.id = qs.employee_id
        WHERE qs.days_until_expiry IS NOT NULL
          AND qs.days_until_expiry <= 90
          AND qs.revoked_on IS NULL
    """)


@dlt.table(comment="Audit-ready record: every scheduled requirement, its verdict, and its evidence.")
def gold_audit_record():
    return spark.sql("""
        SELECT
            current_date() AS as_of_date,
            location, employee_id, employee_name, job_description, supervisor_name,
            work_date, work_center_desc, qualification_id, qualification_name,
            is_regulated, regulation_reference, requirement_source,
            qualification_state, clearance, reason, evidence_reference,
            first_performance_status
        FROM LIVE.gold_shift_clearance
    """)


# ---------------------------------------------------------------------------
# GOLD feature table for the lapse-risk model (Session 3).
# One row per (worker, certification) with leading-signal features and a label
# placeholder. The label (lapsed_before_next_hazardous_job) is left null here
# and populated from history during model development.
# ---------------------------------------------------------------------------

@dlt.table(comment="Lapse-risk features: one row per (worker, qualification) with leading signals.")
def gold_lapse_risk_features():
    return spark.sql("""
        WITH holdings AS (
            SELECT
                eq.employee_id, eq.qualification_id,
                max(eq.expires_on) AS current_expires_on,
                count(*) AS total_certs_held,
                sum(CASE WHEN eq.expires_on IS NOT NULL
                          AND eq.expires_on < current_date() THEN 1 ELSE 0 END) AS prior_lapse_count
            FROM LIVE.silver_employee_qualification eq
            GROUP BY eq.employee_id, eq.qualification_id
        ),
        training_backlog AS (
            SELECT te.employee_id, count(*) AS open_training_count
            FROM LIVE.silver_training_enrolment te
            WHERE te.status IN ('ENROLLED','WAITLIST')
            GROUP BY te.employee_id
        ),
        schedule_pressure AS (
            SELECT employee_id,
                   count(*) AS scheduled_shifts_next_14d
            FROM LIVE.silver_schedule_history
            WHERE work_date BETWEEN current_date() AND date_add(current_date(), 14)
            GROUP BY employee_id
        )
        SELECT
            h.employee_id, h.qualification_id, e.locationname AS location,
            q.is_regulated, q.requires_supervised_first_performance,
            datediff(h.current_expires_on, current_date()) AS days_to_expiry,
            h.prior_lapse_count,
            h.total_certs_held,
            COALESCE(tb.open_training_count, 0) AS training_backlog,
            COALESCE(sp.scheduled_shifts_next_14d, 0) AS schedule_pressure,
            CAST(NULL AS boolean) AS lapsed_before_next_hazardous_job  -- label, set in model dev
        FROM holdings h
        JOIN LIVE.silver_hr_employee e ON e.id = h.employee_id
        JOIN LIVE.silver_qualification q ON q.qualification_id = h.qualification_id
        LEFT JOIN training_backlog tb ON tb.employee_id = h.employee_id
        LEFT JOIN schedule_pressure sp ON sp.employee_id = h.employee_id
    """)
