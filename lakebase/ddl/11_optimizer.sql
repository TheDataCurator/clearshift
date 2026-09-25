-- ---------------------------------------------------------------------------
-- 11_optimizer.sql — the AI decisioning layer, landed in Lakebase.
--
-- Two objects support the What-if studio:
--
--   gate.v_lapse_risk_features  the model's input, one row per (worker,
--                               qualification held), computed from the same
--                               source tables the pipeline's gold feature table
--                               builds from. Keeping the feature logic in one
--                               place means the batch scorer and the online
--                               studio see identical inputs.
--
--   gate.lapse_risk             the model's output, persisted. Scoring is a
--                               nightly batch (model/score_batch.py); the studio
--                               reads these scores and runs the CP-SAT optimizer
--                               live. A solver must not call a serving endpoint
--                               in a loop, and constraints change intraday, so
--                               scoring is offline and optimization is online.
-- ---------------------------------------------------------------------------

-- --- Features -------------------------------------------------------------
-- Mirrors horizontal_dev_serverless_catalog.clearshift.gold_lapse_risk_features,
-- plus proactive_renewal_behavior, the engineered feature the model README flags
-- as the natural gold-layer addition. Held certifications only (not revoked).

CREATE OR REPLACE VIEW gate.v_lapse_risk_features AS
WITH holdings AS (
    SELECT
        eq.employee_id,
        eq.qualification_id,
        max(eq.expires_on)                                              AS current_expires_on,
        count(*)                                                        AS total_certs_held,
        sum(CASE WHEN eq.expires_on IS NOT NULL
                  AND eq.expires_on < current_date THEN 1 ELSE 0 END)   AS prior_lapse_count
    FROM gate.employee_qualification eq
    WHERE eq.revoked_on IS NULL
    GROUP BY eq.employee_id, eq.qualification_id
),
training_backlog AS (
    SELECT te.employee_id, count(*) AS open_training_count
    FROM gate.training_enrolment te
    WHERE te.status IN ('ENROLLED', 'WAITLIST')
    GROUP BY te.employee_id
),
schedule_pressure AS (
    SELECT employee_id, count(*) AS scheduled_shifts_next_14d
    FROM gate.employee_scheduled_workcenter_history
    WHERE work_date BETWEEN current_date AND current_date + INTERVAL '14 days'
    GROUP BY employee_id
),
-- Fraction of a worker's certificate renewals that happened before the prior
-- one expired. Renewing early is protective; a worker who lets certs lapse and
-- re-earns them is higher risk. NULL when the worker has no renewal history yet.
renewals AS (
    SELECT
        employee_id,
        issued_on <= lag(expires_on) OVER (
            PARTITION BY employee_id, qualification_id ORDER BY issued_on
        ) AS renewed_early,
        lag(expires_on) OVER (
            PARTITION BY employee_id, qualification_id ORDER BY issued_on
        ) IS NOT NULL AS is_renewal
    FROM gate.employee_qualification
    WHERE revoked_on IS NULL
),
proactive AS (
    SELECT employee_id,
           avg(CASE WHEN renewed_early THEN 1.0 ELSE 0.0 END) AS proactive_renewal_behavior
    FROM renewals
    WHERE is_renewal
    GROUP BY employee_id
)
SELECT
    h.employee_id,
    h.qualification_id,
    e.locationname                                                      AS location,
    q.is_regulated,
    q.requires_supervised_first_performance,
    (h.current_expires_on - current_date)                               AS days_to_expiry,
    h.prior_lapse_count,
    h.total_certs_held,
    COALESCE(tb.open_training_count, 0)                                 AS training_backlog,
    COALESCE(sp.scheduled_shifts_next_14d, 0)                           AS schedule_pressure,
    ROUND(COALESCE(pr.proactive_renewal_behavior, 0.5)::numeric, 3)     AS proactive_renewal_behavior
FROM holdings h
JOIN gate.hr_employee e     ON e.id = h.employee_id
JOIN gate.qualification q   ON q.qualification_id = h.qualification_id
LEFT JOIN training_backlog tb ON tb.employee_id = h.employee_id
LEFT JOIN schedule_pressure sp ON sp.employee_id = h.employee_id
LEFT JOIN proactive pr         ON pr.employee_id = h.employee_id;


-- --- Persisted model output -----------------------------------------------
-- One score per (worker, qualification). model/score_batch.py writes it; the
-- What-if studio reads it. model_version records which model produced the score
-- so a stale batch is visible rather than silent.

CREATE TABLE IF NOT EXISTS gate.lapse_risk (
    employee_id      text        NOT NULL,
    qualification_id text        NOT NULL,
    lapse_risk       numeric(5,4) NOT NULL,   -- 0..1 predicted probability of lapse
    model_version    text        NOT NULL,
    scored_on        date        NOT NULL DEFAULT current_date,
    PRIMARY KEY (employee_id, qualification_id)
);
