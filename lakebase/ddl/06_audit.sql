-- OSHA audit support
--
-- Two distinct jobs, and conflating them produces a report that serves neither:
--
--   1. Internal audit, run on your own schedule, whose purpose is to find gaps
--      while there is still time to close them.
--   2. Inspection readiness, run when an inspector is on site, whose purpose is
--      to produce proof immediately.
--
-- The data is the same. The framing, the ordering and the acceptable answer are
-- not. An internal audit wants the worst first. An inspector wants a roster they
-- can spot-check, and every name they pick must resolve to evidence.
--
-- Structure follows the training and certification matrix safety managers
-- actually present, and the OSHA VPP on-site evaluation worksheet
-- (Section IV, Safety and Health Training).
--
-- Depends on 05_compliance.sql for gate.v_hazwork_status: the matrix reports OSHA
-- high-hazard authorization alongside the rest, so an inspector sees one roster rather than two.

-- ---------------------------------------------------------------------------
-- Outreach training: the OSHA 10 and 30 hour cards
-- ---------------------------------------------------------------------------
-- Distinct from hazard-specific credentials. These are general awareness cards
-- issued through OSHA's Outreach Training Program, carry a card serial number and
-- a named authorized trainer, and an inspector will ask to see the card itself.
-- 30-hour is the expectation for supervisors.

CREATE TABLE IF NOT EXISTS gate.outreach_card (
    outreach_card_id bigserial PRIMARY KEY,
    employee_id      text NOT NULL,
    course           text NOT NULL CHECK (course IN ('OSHA_10', 'OSHA_30')),
    completed_on     date NOT NULL,
    card_serial      text,
    trainer_name     text,
    trainer_id       text,
    -- Outreach cards do not expire under the federal program, though many
    -- employers impose a five-year refresh. Held as policy, not as regulation.
    policy_refresh_years integer DEFAULT 5,
    UNIQUE (employee_id, course)
);

CREATE INDEX IF NOT EXISTS outreach_card_lookup ON gate.outreach_card (employee_id, course);

-- ---------------------------------------------------------------------------
-- Competent person designations
-- ---------------------------------------------------------------------------
-- OSHA scrutinizes these heavily. A competent person is one capable of
-- identifying hazards and authorized to correct them, and the designation must
-- be assigned in writing for a named hazard category.
--
-- This is an assignment, not a certificate: an inspector asks who is the
-- competent person for excavation at this site, and expects one name.

CREATE TABLE IF NOT EXISTS gate.competent_person (
    competent_person_id bigserial PRIMARY KEY,
    employee_id     text NOT NULL,
    -- Ties the designation to the credential it covers, so the audit can tell
    -- whether a required designation is filled without matching on prose
    qualification_id text REFERENCES gate.qualification (qualification_id),
    hazard_category text NOT NULL,
    site_id         text REFERENCES gate.site (site_id),
    designated_on   date NOT NULL,
    designated_by   text,
    written_ref     text,
    ended_on        date,
    UNIQUE (employee_id, qualification_id, site_id)
);

-- ---------------------------------------------------------------------------
-- Practical evaluations
-- ---------------------------------------------------------------------------
-- Some standards require a hands-on evaluation on a recurring cycle, separately
-- from the credential itself. Powered industrial trucks are the clearest case:
-- 29 CFR 1910.178(l)(4)(iii) requires an evaluation of each operator's
-- performance at least once every three years.
--
-- Holding a current forklift certificate is therefore not sufficient. A citation
-- can follow a missing evaluation even where the credential is in date, which is
-- exactly the kind of gap a certificate-only view hides.

CREATE TABLE IF NOT EXISTS gate.practical_evaluation (
    practical_evaluation_id bigserial PRIMARY KEY,
    employee_id      text NOT NULL,
    qualification_id text NOT NULL REFERENCES gate.qualification (qualification_id),
    evaluated_on     date NOT NULL,
    evaluator_name   text,
    outcome          text NOT NULL DEFAULT 'PASS' CHECK (outcome IN ('PASS', 'FAIL', 'RETRAIN')),
    notes            text,
    UNIQUE (employee_id, qualification_id, evaluated_on)
);

CREATE INDEX IF NOT EXISTS practical_evaluation_lookup
    ON gate.practical_evaluation (employee_id, qualification_id, evaluated_on DESC);

-- Which credentials carry a recurring practical evaluation duty, and how often
ALTER TABLE gate.qualification
    ADD COLUMN IF NOT EXISTS practical_evaluation_months integer;

UPDATE gate.qualification SET practical_evaluation_months = 36
 WHERE qualification_id = 'POWERED_TRUCK' AND practical_evaluation_months IS NULL;
UPDATE gate.qualification SET practical_evaluation_months = 36
 WHERE qualification_id = 'CRANE_SIGNAL' AND practical_evaluation_months IS NULL;

-- Which hazard categories require a competent person named in writing.
-- Deliberately narrow: OSHA names a competent person for specific hazard
-- categories, so the duty is flagged per credential rather than assumed.
ALTER TABLE gate.qualification
    ADD COLUMN IF NOT EXISTS requires_competent_person boolean NOT NULL DEFAULT false;

UPDATE gate.qualification SET requires_competent_person = true
 WHERE qualification_id IN ('CONFINED_SPACE', 'HOT_WORK', 'FALL_PROTECT', 'CRANE_SIGNAL');

-- ---------------------------------------------------------------------------
-- Written programs
-- ---------------------------------------------------------------------------
-- An inspector asks for training records and the written program together. A
-- current credential against a program that was last reviewed four years ago is
-- a finding on its own.

CREATE TABLE IF NOT EXISTS gate.written_program (
    written_program_id bigserial PRIMARY KEY,
    name             text NOT NULL,
    standard_ref     text,
    qualification_id text REFERENCES gate.qualification (qualification_id),
    site_id          text REFERENCES gate.site (site_id),
    version          text,
    last_reviewed_on date,
    review_months    integer NOT NULL DEFAULT 12,
    owner_name       text,
    document_ref     text,
    -- One program per name per site, so re-running the seed is idempotent
    UNIQUE (name, site_id)
);

-- ---------------------------------------------------------------------------
-- Recordable injuries: the 300 log
-- ---------------------------------------------------------------------------
-- Held here only as far as the audit needs it. The purpose is not to reproduce
-- the log but to let a reviewer ask the question that matters: was the injured
-- person qualified for the work they were doing when it happened.

CREATE TABLE IF NOT EXISTS gate.recordable_incident (
    recordable_incident_id bigserial PRIMARY KEY,
    case_number    text UNIQUE,
    employee_id    text,
    site_id        text REFERENCES gate.site (site_id),
    incident_on    date NOT NULL,
    work_center_id text,
    classification text CHECK (classification IN
        ('DAYS_AWAY', 'RESTRICTED_TRANSFER', 'OTHER_RECORDABLE', 'FIRST_AID_ONLY')),
    days_away      integer DEFAULT 0,
    days_restricted integer DEFAULT 0,
    description    text
);

-- ---------------------------------------------------------------------------
-- Seed
-- ---------------------------------------------------------------------------

INSERT INTO gate.outreach_card (employee_id, course, completed_on, card_serial, trainer_name, trainer_id)
VALUES
  ('40118','OSHA_10', CURRENT_DATE - interval '700 days','OSHA10-4418872','M. Sandoval','OT-22841'),
  ('40119','OSHA_10', CURRENT_DATE - interval '980 days','OSHA10-4302119','M. Sandoval','OT-22841'),
  ('40120','OSHA_10', CURRENT_DATE - interval '35 days', 'OSHA10-4691503','M. Sandoval','OT-22841'),
  ('40121','OSHA_10', CURRENT_DATE - interval '1500 days','OSHA10-3988201','K. Whitfield','OT-19677'),
  ('40122','OSHA_10', CURRENT_DATE - interval '560 days','OSHA10-4501338','M. Sandoval','OT-22841'),
  ('40123','OSHA_10', CURRENT_DATE - interval '820 days','OSHA10-4377265','M. Sandoval','OT-22841'),
  ('40124','OSHA_10', CURRENT_DATE - interval '1900 days','OSHA10-3711044','K. Whitfield','OT-19677'),
  ('40125','OSHA_10', CURRENT_DATE - interval '740 days','OSHA10-4423910','M. Sandoval','OT-22841'),
  -- Supervisors carry the 30 hour card. Gerald Pruitt deliberately does not,
  -- so the audit has a supervisor-level gap to surface.
  ('40101','OSHA_30', CURRENT_DATE - interval '1100 days','OSHA30-2214887','K. Whitfield','OT-19677'),
  ('40102','OSHA_30', CURRENT_DATE - interval '1350 days','OSHA30-2109923','K. Whitfield','OT-19677'),
  ('40100','OSHA_30', CURRENT_DATE - interval '900 days','OSHA30-2330156','K. Whitfield','OT-19677'),
  ('40210','OSHA_10', CURRENT_DATE - interval '640 days','OSHA10-4466701','R. Delacroix','OT-24115'),
  ('40211','OSHA_10', CURRENT_DATE - interval '480 days','OSHA10-4552284','R. Delacroix','OT-24115'),
  ('40201','OSHA_30', CURRENT_DATE - interval '1600 days','OSHA30-2044371','R. Delacroix','OT-24115')
ON CONFLICT DO NOTHING;

INSERT INTO gate.competent_person (employee_id, qualification_id, hazard_category, site_id, designated_on, designated_by, written_ref)
VALUES
  ('40102','CONFINED_SPACE','Confined Space Entry','PEIL', CURRENT_DATE - interval '400 days','D. Whitlock','MEMO-PEIL-CS-01'),
  ('40124','CRANE_SIGNAL',  'Crane and Hoist',     'PEIL', CURRENT_DATE - interval '300 days','D. Whitlock','MEMO-PEIL-CR-01'),
  ('40101','HOT_WORK',      'Hot Work',            'PEIL', CURRENT_DATE - interval '520 days','D. Whitlock','MEMO-PEIL-HW-01'),
  ('40201','HOT_WORK',      'Hot Work',            'GRMI', CURRENT_DATE - interval '610 days','M. Ihde',    'MEMO-GRMI-HW-01')
  -- Fall Protection at Peoria is deliberately unassigned: a required
  -- designation with nobody named is a finding, and one an internal audit
  -- should catch before an inspector does.
ON CONFLICT DO NOTHING;

INSERT INTO gate.practical_evaluation (employee_id, qualification_id, evaluated_on, evaluator_name, outcome)
VALUES
  -- Yvette Coleridge: forklift certificate current, evaluation overdue past the
  -- three year mark. The case a certificate-only view misses entirely.
  ('40125','POWERED_TRUCK', CURRENT_DATE - interval '1210 days','C. Lindahl','PASS'),
  ('40122','POWERED_TRUCK', CURRENT_DATE - interval '500 days', 'C. Lindahl','PASS'),
  ('40124','CRANE_SIGNAL',  CURRENT_DATE - interval '200 days', 'D. Whitlock','PASS'),
  ('40121','CRANE_SIGNAL',  CURRENT_DATE - interval '1150 days','D. Whitlock','PASS'),
  ('40211','POWERED_TRUCK', CURRENT_DATE - interval '300 days', 'M. Ihde','PASS')
ON CONFLICT DO NOTHING;

INSERT INTO gate.written_program (name, standard_ref, qualification_id, site_id, version, last_reviewed_on, review_months, owner_name, document_ref)
VALUES
  ('Permit-Required Confined Space Program','29 CFR 1910.146','CONFINED_SPACE','PEIL','4.2', CURRENT_DATE - interval '150 days', 12,'Safety team','PRG-CS-42'),
  ('Hot Work and Welding Program',          '29 CFR 1910.252','HOT_WORK',      'PEIL','3.0', CURRENT_DATE - interval '300 days', 12,'Safety team','PRG-HW-30'),
  ('Powered Industrial Truck Program',      '29 CFR 1910.178','POWERED_TRUCK', 'PEIL','2.6', CURRENT_DATE - interval '410 days', 12,'Safety team','PRG-PIT-26'),
  ('Lockout / Tagout Energy Control',       '29 CFR 1910.147','LOTO',          'PEIL','5.1', CURRENT_DATE - interval '90 days',  12,'Maintenance','PRG-LOTO-51'),
  ('Respiratory Protection Program',        '29 CFR 1910.134','RESPIRATOR',    'PEIL','3.3', CURRENT_DATE - interval '200 days', 12,'Safety team','PRG-RESP-33'),
  ('Fall Protection Program',               '29 CFR 1926.503','FALL_PROTECT',  'PEIL','2.0', CURRENT_DATE - interval '500 days', 12,'Safety team','PRG-FALL-20'),
  ('Hazard Communication Program',          '29 CFR 1910.1200', NULL,          'PEIL','6.0', CURRENT_DATE - interval '60 days',  12,'Safety team','PRG-HAZCOM-60')
ON CONFLICT DO NOTHING;

INSERT INTO gate.recordable_incident (case_number, employee_id, site_id, incident_on, work_center_id, classification, days_away, days_restricted, description)
VALUES
  ('PEIL-2026-014','40123','PEIL', CURRENT_DATE - interval '55 days','14309011-000-0852-5608','RESTRICTED_TRANSFER',0,6,'Coating overspray exposure; respirator fit questioned'),
  ('PEIL-2026-009','40120','PEIL', CURRENT_DATE - interval '120 days','14317061-000-0106-1061','OTHER_RECORDABLE',0,0,'Minor arc flash burn during tack welding'),
  ('PEIL-2026-003','40122','PEIL', CURRENT_DATE - interval '260 days','14317015-001-0026-516','DAYS_AWAY',4,0,'Struck by load shifting from powered industrial truck')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- The training and certification matrix
-- ---------------------------------------------------------------------------
-- One row per worker: the roster an inspector spot-checks. Outreach card,
-- specialized credentials, competent person designations, practical evaluation
-- status, and whether each resolves to evidence.

CREATE OR REPLACE VIEW gate.v_training_matrix AS
WITH outreach AS (
    SELECT employee_id,
           max(completed_on) FILTER (WHERE course = 'OSHA_10') AS osha10_on,
           max(card_serial)  FILTER (WHERE course = 'OSHA_10') AS osha10_serial,
           max(trainer_name) FILTER (WHERE course = 'OSHA_10') AS osha10_trainer,
           max(completed_on) FILTER (WHERE course = 'OSHA_30') AS osha30_on,
           max(card_serial)  FILTER (WHERE course = 'OSHA_30') AS osha30_serial,
           max(trainer_name) FILTER (WHERE course = 'OSHA_30') AS osha30_trainer
      FROM gate.outreach_card GROUP BY employee_id
),
req AS (
    -- Everything the person's current work center or job demands
    SELECT DISTINCT e.id AS employee_id, wr.qualification_id
      FROM gate.hr_employee e
      JOIN gate.employee_current_workcenter_assignment a ON a.employee_id = e.id
      JOIN gate.workcenter_requirement wr ON wr.work_center_id = a.work_center_id
       AND (wr.effective_to IS NULL OR wr.effective_to > CURRENT_DATE)
    UNION
    SELECT DISTINCT e.id, jr.qualification_id
      FROM gate.hr_employee e
      JOIN gate.job_requirement jr ON jr.job_description = e.descr
       AND (jr.effective_to IS NULL OR jr.effective_to > CURRENT_DATE)
),
creds AS (
    SELECT r.employee_id,
           count(*) AS required_count,
           count(*) FILTER (WHERE COALESCE(qs.state,'MISSING') IN ('CURRENT','EXPIRING')) AS held_count,
           string_agg(DISTINCT q.name, ', ' ORDER BY q.name)
             FILTER (WHERE COALESCE(qs.state,'MISSING') NOT IN ('CURRENT','EXPIRING')) AS missing_list
      FROM req r
      JOIN gate.qualification q ON q.qualification_id = r.qualification_id
      LEFT JOIN gate.v_qualification_state qs
             ON qs.employee_id = r.employee_id AND qs.qualification_id = r.qualification_id
     WHERE q.is_regulated
     GROUP BY r.employee_id
),
-- Practical evaluations that are required and overdue
prac AS (
    SELECT r.employee_id,
           string_agg(DISTINCT q.name, ', ' ORDER BY q.name) AS overdue_list,
           count(*) AS overdue_count
      FROM req r
      JOIN gate.qualification q ON q.qualification_id = r.qualification_id
     WHERE q.practical_evaluation_months IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM gate.practical_evaluation pe
            WHERE pe.employee_id = r.employee_id
              AND pe.qualification_id = r.qualification_id
              AND pe.outcome = 'PASS'
              AND pe.evaluated_on > CURRENT_DATE - (q.practical_evaluation_months || ' months')::interval
       )
     GROUP BY r.employee_id
),
cp AS (
    SELECT employee_id, string_agg(hazard_category, ', ' ORDER BY hazard_category) AS competent_for
      FROM gate.competent_person
     WHERE ended_on IS NULL
     GROUP BY employee_id
),
-- OSHA high-hazard authorization applies only to some employees. Held as its own
-- status so "not applicable" is stated rather than looking like a missing record.
hazwork AS (
    SELECT employee_id, craft, is_safety_related, not_applicable_reason,
           expires_on AS hazwork_expires_on, hazwork_status
      FROM gate.v_hazwork_status
)
SELECT
    e.locationname AS location,
    e.id           AS employee_id,
    e.name         AS employee_name,
    e.descr        AS job_description,
    e.deptname     AS department,
    e.supvid       AS supervisor_id,
    e.supvname     AS supervisor_name,
    e.careerleveldescription,
    -- A supervisory role is the trigger for the 30 hour expectation
    (e.descr ILIKE '%supervisor%' OR e.descr ILIKE '%manager%'
     OR e.careerleveldescription ILIKE '%supervisor%'
     OR e.careerleveldescription ILIKE '%leadership%') AS is_supervisory,
    o.osha10_on, o.osha10_serial, o.osha10_trainer,
    o.osha30_on, o.osha30_serial, o.osha30_trainer,
    COALESCE(c.required_count, 0) AS credentials_required,
    COALESCE(c.held_count, 0)     AS credentials_held,
    c.missing_list,
    COALESCE(p.overdue_count, 0)  AS practical_overdue_count,
    p.overdue_list                AS practical_overdue_list,
    cp.competent_for,
    e.loto_role,
    e.hazcom_trained_on,
    (e.hazcom_trained_on IS NOT NULL) AS hazcom_trained,
    f.craft            AS hazwork_craft,
    f.is_safety_related AS hazwork_regulated,
    f.not_applicable_reason AS hazwork_na_reason,
    f.hazwork_expires_on,
    COALESCE(f.hazwork_status, 'NO_RECORD') AS hazwork_status,
    -- The verdict an inspector's spot-check would produce
    CASE
        WHEN COALESCE(c.required_count,0) > COALESCE(c.held_count,0) THEN 'GAP'
        WHEN f.is_safety_related AND f.hazwork_status = 'EXPIRED'          THEN 'HAZWORK_EXPIRED'
        WHEN COALESCE(p.overdue_count,0) > 0                          THEN 'EVALUATION_OVERDUE'
        WHEN f.is_safety_related AND f.hazwork_status = 'OVERSIGHT_OVERDUE' THEN 'HAZWORK_REEVAL_OVERDUE'
        WHEN e.hazcom_trained_on IS NULL                              THEN 'NO_HAZCOM'
        WHEN o.osha10_on IS NULL AND o.osha30_on IS NULL              THEN 'NO_OUTREACH_CARD'
        WHEN (e.descr ILIKE '%supervisor%' OR e.careerleveldescription ILIKE '%supervisor%'
              OR e.careerleveldescription ILIKE '%leadership%')
             AND o.osha30_on IS NULL                                  THEN 'SUPERVISOR_NO_30HR'
        ELSE 'COMPLETE'
    END AS audit_status
FROM gate.hr_employee e
LEFT JOIN outreach o  ON o.employee_id = e.id
LEFT JOIN creds c     ON c.employee_id = e.id
LEFT JOIN prac p      ON p.employee_id = e.id
LEFT JOIN cp          ON cp.employee_id = e.id
LEFT JOIN hazwork f       ON f.employee_id = e.id
WHERE e.paystatus = 'A';

-- ---------------------------------------------------------------------------
-- Findings: what an internal audit should fix before an inspection
-- ---------------------------------------------------------------------------
-- Ordered by how a citation would land, not by how easily it is fixed.

CREATE OR REPLACE VIEW gate.v_audit_finding AS
-- Unmet credential requirements
SELECT
    location, 'CREDENTIAL' AS finding_type, 1 AS severity_rank,
    employee_id, employee_name, supervisor_id,
    'Required credential not held: ' || missing_list AS finding,
    'Worker is assigned to work requiring a credential they do not currently hold' AS why
  FROM gate.v_training_matrix
 WHERE missing_list IS NOT NULL

UNION ALL

-- Practical evaluations past their cycle
SELECT
    location, 'PRACTICAL_EVALUATION', 2,
    employee_id, employee_name, supervisor_id,
    'Practical evaluation overdue: ' || practical_overdue_list,
    'Certificate may be current, but the recurring hands-on evaluation is past due'
  FROM gate.v_training_matrix
 WHERE practical_overdue_count > 0

UNION ALL

-- Outreach card gaps. One row per person: a supervisor holding no card at all
-- has a single problem, not two, and reporting it twice inflates the count an
-- executive reads as exposure.
SELECT
    location, 'OUTREACH_CARD', 3,
    employee_id, employee_name, supervisor_id,
    CASE
        WHEN osha10_on IS NULL AND osha30_on IS NULL AND is_supervisory
            THEN 'Supervisory role with no OSHA outreach card on record'
        WHEN osha10_on IS NULL AND osha30_on IS NULL
            THEN 'No OSHA outreach card on record'
        ELSE 'Supervisory role without OSHA 30-hour card'
    END,
    CASE
        WHEN osha10_on IS NULL AND osha30_on IS NULL
            THEN 'An inspector will ask to see the card; no record is the same as no card'
        ELSE 'The 30-hour card is the expectation for supervisory roles'
    END
  FROM gate.v_training_matrix
 WHERE (osha10_on IS NULL AND osha30_on IS NULL)
    OR (is_supervisory AND osha30_on IS NULL)

UNION ALL

-- Nobody designated competent for a hazard the site actually runs
SELECT DISTINCT
    s.locationname, 'COMPETENT_PERSON', 2,
    NULL, NULL, NULL,
    'No competent person designated for ' || q.name,
    'A required designation with nobody named in writing is a finding on its own'
  FROM gate.site s
  JOIN gate.v_coverage cv ON cv.location = s.locationname
  JOIN gate.qualification q ON q.qualification_id = cv.qualification_id
 WHERE q.requires_competent_person
   AND NOT EXISTS (
       SELECT 1 FROM gate.competent_person c
        WHERE c.site_id = s.site_id AND c.ended_on IS NULL
          AND c.qualification_id = q.qualification_id
   )

UNION ALL

-- Written programs past their review cycle
SELECT DISTINCT
    s.locationname, 'WRITTEN_PROGRAM', 3,
    NULL, NULL, NULL,
    'Written program overdue for review: ' || w.name
      || ' (last reviewed ' || w.last_reviewed_on || ')',
    'Inspectors ask for training records and the written program together'
  FROM gate.written_program w
  JOIN gate.site s ON s.site_id = w.site_id
 WHERE w.last_reviewed_on < CURRENT_DATE - (w.review_months || ' months')::interval

UNION ALL

-- Hazard communication is an all-hands duty
SELECT
    location, 'HAZCOM', 2,
    employee_id, employee_name, supervisor_id,
    'No hazard communication training on record',
    'HazCom applies to every employee exposed to hazardous chemicals'
  FROM gate.v_training_matrix
 WHERE NOT hazcom_trained

UNION ALL

-- OSHA high-hazard authorization, where it applies
SELECT
    location, 'OSHA_HAZWORK',
    CASE WHEN hazwork_status = 'EXPIRED' THEN 1 ELSE 2 END,
    employee_id, employee_name, supervisor_id,
    CASE hazwork_status
        WHEN 'EXPIRED'           THEN 'OSHA high-hazard authorization expired (' || COALESCE(hazwork_craft,'craft not recorded') || ')'
        WHEN 'OVERSIGHT_OVERDUE' THEN 'OSHA high-hazard re-evaluation overdue (' || COALESCE(hazwork_craft,'craft not recorded') || ')'
        ELSE 'OSHA high-hazard authorization missing for a regulated role'
    END,
    'OSHA high-hazard authorization applies to employees performing lockout/tagout, confined space or hot work'
  FROM gate.v_training_matrix
 WHERE hazwork_regulated
   AND hazwork_status IN ('EXPIRED', 'OVERSIGHT_OVERDUE', 'NOT_QUALIFIED');

-- ---------------------------------------------------------------------------
-- Recordable incidents, cross-referenced to qualification
-- ---------------------------------------------------------------------------
-- The question a reviewer wants answered: was this person qualified for the work
-- they were doing when it happened.

CREATE OR REPLACE VIEW gate.v_incident_review AS
SELECT
    i.case_number,
    s.locationname AS location,
    i.incident_on,
    i.classification,
    i.days_away,
    i.days_restricted,
    i.description,
    e.name         AS employee_name,
    e.descr        AS job_description,
    e.supvid       AS supervisor_id,
    i.work_center_id,
    -- Credentials the work center demanded at the time
    (SELECT string_agg(q.name, ', ' ORDER BY q.name)
       FROM gate.workcenter_requirement wr
       JOIN gate.qualification q ON q.qualification_id = wr.qualification_id
      WHERE wr.work_center_id = i.work_center_id
        AND wr.effective_from <= i.incident_on
        AND (wr.effective_to IS NULL OR wr.effective_to > i.incident_on)) AS required_at_time,
    -- Of those, any the person did not hold on the day
    (SELECT string_agg(q.name, ', ' ORDER BY q.name)
       FROM gate.workcenter_requirement wr
       JOIN gate.qualification q ON q.qualification_id = wr.qualification_id
      WHERE wr.work_center_id = i.work_center_id
        AND wr.effective_from <= i.incident_on
        AND (wr.effective_to IS NULL OR wr.effective_to > i.incident_on)
        AND NOT EXISTS (
            SELECT 1 FROM gate.employee_qualification eq
             WHERE eq.employee_id = i.employee_id
               AND eq.qualification_id = wr.qualification_id
               AND eq.issued_on <= i.incident_on
               AND (eq.expires_on IS NULL OR eq.expires_on > i.incident_on)
               AND (eq.revoked_on IS NULL OR eq.revoked_on > i.incident_on)
        )) AS unheld_at_time
FROM gate.recordable_incident i
LEFT JOIN gate.hr_employee e ON e.id = i.employee_id
LEFT JOIN gate.site s ON s.site_id = i.site_id;
