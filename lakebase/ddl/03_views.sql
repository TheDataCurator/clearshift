-- Qualification Gate — the logic
--
-- Five views. The first two are building blocks; the last three are what the
-- application reads.
--
-- Point these at the real synced tables by changing the three references in
-- v_requirement_for_shift and v_qualification_state. Nothing else needs editing.

-- ---------------------------------------------------------------------------
-- 1. What is required for a given shift
-- ---------------------------------------------------------------------------
-- Combines the work-center requirement with the job requirement, because both
-- apply. A welder scheduled into a tank needs the welding qualification because
-- of the job and confined space entry because of the location.

-- A qualification can be demanded by both the work center and the job. That is
-- one requirement with two reasons, not two requirements, so the sources are
-- collapsed into a single row. Without this a supervisor sees the same person
-- flagged twice for the same thing.

CREATE OR REPLACE VIEW gate.v_requirement_for_shift AS
WITH sources AS (
    SELECT
        h.employee_id,
        h.work_date,
        h.scheduled_wc_code   AS work_center_id,
        h.scheduled_wc_desc   AS work_center_desc,
        r.qualification_id,
        'WORK_CENTER'         AS requirement_source
    FROM gate.employee_scheduled_workcenter_history h
    JOIN gate.workcenter_requirement r
         ON r.work_center_id = h.scheduled_wc_code
        AND r.effective_from <= h.work_date
        AND (r.effective_to IS NULL OR r.effective_to > h.work_date)

    UNION ALL

    SELECT
        h.employee_id,
        h.work_date,
        h.scheduled_wc_code,
        h.scheduled_wc_desc,
        j.qualification_id,
        'JOB'
    FROM gate.employee_scheduled_workcenter_history h
    JOIN gate.hr_employee e
         ON e.id = h.employee_id
    JOIN gate.job_requirement j
         ON j.job_description = e.descr
        AND j.effective_from <= h.work_date
        AND (j.effective_to IS NULL OR j.effective_to > h.work_date)
)
SELECT
    employee_id,
    work_date,
    work_center_id,
    work_center_desc,
    qualification_id,
    string_agg(DISTINCT requirement_source, '+' ORDER BY requirement_source) AS requirement_source
FROM sources
GROUP BY employee_id, work_date, work_center_id, work_center_desc, qualification_id;

-- ---------------------------------------------------------------------------
-- 2. Whether a person held a qualification on a given date
-- ---------------------------------------------------------------------------
-- Temporal, so an audit can ask about any date rather than only today.
-- Site scoping is enforced here: a qualification scoped to one plant does not
-- clear work at another.

CREATE OR REPLACE VIEW gate.v_qualification_state AS
SELECT
    eq.employee_id,
    eq.qualification_id,
    q.name             AS qualification_name,
    q.is_regulated,
    q.regulation_reference,
    q.requires_supervised_first_performance,
    q.scope,
    q.renewal_warning_days,
    eq.issued_on,
    eq.expires_on,
    eq.revoked_on,
    eq.revoked_reason,
    eq.scoped_to,
    eq.evidence_reference,
    e.locationname     AS employee_location,
    CASE
        WHEN eq.revoked_on IS NOT NULL AND eq.revoked_on <= CURRENT_DATE THEN 'REVOKED'
        WHEN eq.expires_on IS NOT NULL AND eq.expires_on <  CURRENT_DATE THEN 'EXPIRED'
        WHEN q.scope IN ('SITE_SPECIFIC', 'ASSET_SPECIFIC')
             AND eq.scoped_to IS NOT NULL
             AND eq.scoped_to <> e.locationname                          THEN 'OUT_OF_SCOPE'
        WHEN eq.expires_on IS NOT NULL
             AND eq.expires_on <= CURRENT_DATE + (q.renewal_warning_days || ' days')::interval
                                                                          THEN 'EXPIRING'
        ELSE 'CURRENT'
    END AS state,
    CASE WHEN eq.expires_on IS NOT NULL
         THEN (eq.expires_on - CURRENT_DATE) END AS days_until_expiry
FROM gate.employee_qualification eq
JOIN gate.qualification q ON q.qualification_id = eq.qualification_id
JOIN gate.hr_employee   e ON e.id               = eq.employee_id;

-- ---------------------------------------------------------------------------
-- 3. Shift clearance — the closed loop
-- ---------------------------------------------------------------------------
-- Takes the forward schedule and resolves every requirement to a verdict with
-- evidence attached. This is the piece that turns "someone should check" into
-- "cleared" or "not cleared, for this reason".
--
-- first_time_at_work_center reproduces the existing first-occurrence detection
-- and then goes further: it says which qualification the unfamiliar work center
-- demands and whether the person actually holds it.
--
-- Ambiguity resolves toward flagging. A missing requirement row or an unreadable
-- scope produces NOT_CLEARED rather than silence.

-- Two distinct notions of "first time", and conflating them produces noise.
--
--   first_time_at_work_center — has this person worked this work center before?
--     Reproduces the existing first-occurrence detection. Useful context, but
--     on its own it is not a reason to require supervision: a welder moving
--     between two welding bays is not doing anything new.
--
--   first_time_performing — has this person ever worked anywhere that demanded
--     this qualification? This is the one that matters for safety, because it
--     identifies the genuine first performance of the hazardous activity.
--
-- For site-scoped qualifications the site is part of the question, since an
-- authorization to enter confined spaces at one plant says nothing about the
-- vessels at another.

CREATE OR REPLACE VIEW gate.v_shift_clearance AS
WITH worked AS (
    -- Days actually worked, not merely scheduled. Where an unplanned transfer
    -- occurred the actual work center is what counts as experience.
    SELECT
        employee_id,
        work_date,
        COALESCE(actual_wc_code, scheduled_wc_code) AS work_center_id
    FROM gate.employee_scheduled_workcenter_history
    WHERE assignment_status <> 'SCHEDULED'
),
-- Which qualifications each past day of work exercised.
--
-- Only days where the person actually held the qualification count as
-- experience. Work performed while unqualified is an exposure, not training,
-- and must not be allowed to satisfy the supervised-first-performance rule.
-- Without this condition an unauthorized transfer would silently discharge the
-- very control that exists to catch it.
exercised AS (
    SELECT DISTINCT
        w.employee_id,
        w.work_date,
        wr.qualification_id,
        e.locationname AS location
    FROM worked w
    JOIN gate.workcenter_requirement wr
         ON wr.work_center_id = w.work_center_id
        AND wr.effective_from <= w.work_date
        AND (wr.effective_to IS NULL OR wr.effective_to > w.work_date)
    JOIN gate.hr_employee e ON e.id = w.employee_id
    JOIN gate.employee_qualification eq
         ON eq.employee_id      = w.employee_id
        AND eq.qualification_id = wr.qualification_id
        AND eq.issued_on       <= w.work_date
        AND (eq.expires_on IS NULL OR eq.expires_on  > w.work_date)
        AND (eq.revoked_on IS NULL OR eq.revoked_on  > w.work_date)
),
req AS (
    SELECT
        r.employee_id,
        r.work_date,
        r.work_center_id,
        r.work_center_desc,
        r.qualification_id,
        r.requirement_source,
        NOT EXISTS (
            SELECT 1 FROM worked w
            WHERE w.employee_id    = r.employee_id
              AND w.work_center_id = r.work_center_id
              AND w.work_date      < r.work_date
        ) AS first_time_at_work_center,
        NOT EXISTS (
            SELECT 1
            FROM exercised x
            JOIN gate.qualification qq ON qq.qualification_id = r.qualification_id
            WHERE x.employee_id      = r.employee_id
              AND x.qualification_id = r.qualification_id
              AND x.work_date        < r.work_date
              -- Site-scoped qualifications need prior experience at this site
              AND (qq.scope = 'PORTABLE' OR x.location = e2.locationname)
        ) AS first_time_performing
    FROM gate.v_requirement_for_shift r
    JOIN gate.hr_employee e2 ON e2.id = r.employee_id
)
SELECT
    req.employee_id,
    e.name              AS employee_name,
    e.descr             AS job_description,
    e.deptname          AS department,
    e.locationname      AS location,
    e.supvid            AS supervisor_id,
    e.supvname          AS supervisor_name,
    req.work_date,
    req.work_center_id,
    req.work_center_desc,
    req.qualification_id,
    COALESCE(qs.qualification_name, q.name) AS qualification_name,
    COALESCE(qs.is_regulated, q.is_regulated) AS is_regulated,
    COALESCE(qs.regulation_reference, q.regulation_reference) AS regulation_reference,
    req.requirement_source,
    req.first_time_at_work_center,
    req.first_time_performing,
    COALESCE(qs.state, 'MISSING') AS qualification_state,
    qs.expires_on,
    qs.days_until_expiry,
    qs.revoked_reason,
    qs.scoped_to,
    qs.evidence_reference,
    fp.status           AS first_performance_status,
    fp.supervised_by,
    -- The verdict
    CASE
        WHEN qs.state IS NULL                       THEN 'NOT_CLEARED'
        WHEN qs.state IN ('EXPIRED','REVOKED','OUT_OF_SCOPE') THEN 'NOT_CLEARED'
        WHEN COALESCE(qs.requires_supervised_first_performance, false)
             AND req.first_time_performing
             AND COALESCE(fp.status, 'PENDING') = 'PENDING'
                                                    THEN 'SUPERVISION_REQUIRED'
        WHEN qs.state = 'EXPIRING'                  THEN 'CLEARED_EXPIRING'
        ELSE 'CLEARED'
    END AS clearance,
    -- Plain-language reason, for the floor rather than for an analyst
    CASE
        WHEN qs.state IS NULL
            THEN 'No record of ' || COALESCE(q.name, req.qualification_id)
        WHEN qs.state = 'EXPIRED'
            THEN qs.qualification_name || ' lapsed ' || (CURRENT_DATE - qs.expires_on) || ' days ago'
        WHEN qs.state = 'REVOKED'
            THEN qs.qualification_name || ' revoked: ' || COALESCE(qs.revoked_reason, 'no reason recorded')
        WHEN qs.state = 'OUT_OF_SCOPE'
            THEN qs.qualification_name || ' is authorized for ' || COALESCE(qs.scoped_to, 'another site')
                 || ', not ' || e.locationname
        WHEN COALESCE(qs.requires_supervised_first_performance, false)
             AND req.first_time_performing
             AND COALESCE(fp.status, 'PENDING') = 'PENDING'
            THEN 'First time performing ' || qs.qualification_name || ', in ' || req.work_center_desc
                 || '. Supervised performance required.'
        WHEN qs.state = 'EXPIRING'
            THEN qs.qualification_name || ' expires in ' || qs.days_until_expiry || ' days'
        ELSE 'Current'
    END AS reason
FROM req
JOIN gate.hr_employee e ON e.id = req.employee_id
LEFT JOIN gate.qualification q ON q.qualification_id = req.qualification_id
LEFT JOIN gate.v_qualification_state qs
       ON qs.employee_id      = req.employee_id
      AND qs.qualification_id = req.qualification_id
LEFT JOIN gate.first_performance fp
       ON fp.employee_id      = req.employee_id
      AND fp.qualification_id = req.qualification_id
      AND fp.work_center_id   = req.work_center_id;

-- ---------------------------------------------------------------------------
-- 4. Point-in-time site roster
-- ---------------------------------------------------------------------------
-- The audit answer: everyone at a location, what they were required to hold,
-- and whether they held it. Parameterise on a date by replacing CURRENT_DATE.

-- Every view that the scope predicate touches must expose both location and
-- supervisor_id, so that one predicate applies uniformly. Omitting supervisor_id
-- from a view forces the caller to weaken the predicate, which silently widens
-- a crew supervisor's visibility to the whole site.

CREATE OR REPLACE VIEW gate.v_site_roster AS
SELECT
    e.locationname   AS location,
    e.id             AS employee_id,
    e.name           AS employee_name,
    e.descr          AS job_description,
    e.deptname       AS department,
    e.supvid         AS supervisor_id,
    e.supvname       AS supervisor_name,
    a.work_center_desc AS current_work_center,
    q.qualification_id,
    q.name           AS qualification_name,
    q.is_regulated,
    q.regulation_reference,
    COALESCE(qs.state, 'MISSING') AS qualification_state,
    qs.issued_on,
    qs.expires_on,
    qs.days_until_expiry,
    qs.evidence_reference
FROM gate.hr_employee e
LEFT JOIN gate.employee_current_workcenter_assignment a ON a.employee_id = e.id
-- Everything the person's current work center or job demands
LEFT JOIN LATERAL (
    SELECT wr.qualification_id FROM gate.workcenter_requirement wr
     WHERE wr.work_center_id = a.work_center_id
       AND (wr.effective_to IS NULL OR wr.effective_to > CURRENT_DATE)
    UNION
    SELECT jr.qualification_id FROM gate.job_requirement jr
     WHERE jr.job_description = e.descr
       AND (jr.effective_to IS NULL OR jr.effective_to > CURRENT_DATE)
) req ON true
LEFT JOIN gate.qualification q ON q.qualification_id = req.qualification_id
LEFT JOIN gate.v_qualification_state qs
       ON qs.employee_id      = e.id
      AND qs.qualification_id = req.qualification_id
WHERE e.paystatus = 'A'
  AND req.qualification_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Unplanned transfer
-- ---------------------------------------------------------------------------
-- The case a clock-in gate cannot catch: cleared at the start of the shift,
-- then moved to work they are not qualified for. Detectable because the source
-- records scheduled and actual work center separately.

CREATE OR REPLACE VIEW gate.v_unplanned_transfer AS
SELECT
    h.employee_id,
    e.name         AS employee_name,
    e.locationname AS location,
    e.supvid       AS supervisor_id,
    e.supvname     AS supervisor_name,
    h.work_date,
    h.scheduled_wc_desc,
    h.actual_wc_desc,
    h.wc_count_on_date,
    h.variance_hours,
    r.qualification_id,
    q.name         AS qualification_name,
    COALESCE(qs.state, 'MISSING') AS qualification_state
FROM gate.employee_scheduled_workcenter_history h
JOIN gate.hr_employee e ON e.id = h.employee_id
JOIN gate.workcenter_requirement r
     ON r.work_center_id = h.actual_wc_code
    AND (r.effective_to IS NULL OR r.effective_to > h.work_date)
JOIN gate.qualification q ON q.qualification_id = r.qualification_id
LEFT JOIN gate.v_qualification_state qs
       ON qs.employee_id      = h.employee_id
      AND qs.qualification_id = r.qualification_id
WHERE h.actual_wc_code IS NOT NULL
  AND h.actual_wc_code <> h.scheduled_wc_code
  AND COALESCE(qs.state, 'MISSING') NOT IN ('CURRENT', 'EXPIRING');

-- ---------------------------------------------------------------------------
-- 6. Renewal pipeline
-- ---------------------------------------------------------------------------
-- What the training coordinator schedules against.

CREATE OR REPLACE VIEW gate.v_renewal_pipeline AS
SELECT
    qs.employee_id,
    e.name          AS employee_name,
    e.locationname  AS location,
    e.deptname      AS department,
    e.supvid        AS supervisor_id,
    e.supvname      AS supervisor_name,
    qs.qualification_id,
    qs.qualification_name,
    qs.is_regulated,
    qs.expires_on,
    qs.days_until_expiry,
    CASE
        WHEN qs.days_until_expiry < 0  THEN 'LAPSED'
        WHEN qs.days_until_expiry <= 30 THEN 'DUE_30'
        WHEN qs.days_until_expiry <= 60 THEN 'DUE_60'
        ELSE 'DUE_90'
    END AS bucket
FROM gate.v_qualification_state qs
JOIN gate.hr_employee e ON e.id = qs.employee_id
WHERE qs.days_until_expiry IS NOT NULL
  AND qs.days_until_expiry <= 90
  AND qs.revoked_on IS NULL;
