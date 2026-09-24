-- Corporate learning: the second module
--
-- One system, two populations, and the difference is not the content. It is the
-- consequence of not completing.
--
--   Plant.     A credential gates work assignment. Miss it and the person cannot
--              perform the job. The trigger is the work center: where you stand
--              determines what you must hold.
--
--   Corporate. An obligation carries a due date. Miss it and it escalates to a
--              manager; nobody is stopped from working. The trigger is the role:
--              who you are determines what you owe.
--
-- Both share the same spine of person, course, completion and record. Modeling
-- them as one system with two resolvers avoids the usual outcome, which is a
-- second learning system bolted on later for office staff.
--
-- A third category sits alongside both: development. Elective, no due date,
-- tracked because it is the reason people engage with the system voluntarily.

-- ---------------------------------------------------------------------------
-- Policy requirements
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS gate.learning_policy (
    policy_id     text PRIMARY KEY,
    title         text NOT NULL,
    category      text NOT NULL CHECK (category IN ('COMPLIANCE', 'ROLE', 'DEVELOPMENT')),
    -- The distinction that makes one module out of two
    enforcement   text NOT NULL CHECK (enforcement IN ('GATES_WORK', 'DUE_DATE', 'ELECTIVE')),
    -- Who owes it. Resolved against hr_employee rather than a work center.
    applies_to    text NOT NULL DEFAULT 'ALL_STAFF'
                  CHECK (applies_to IN ('ALL_STAFF', 'OFFICE', 'PLANT', 'DEPARTMENT', 'SUPERVISORY')),
    applies_value text,
    cadence_months integer,
    -- Days before due that it should surface
    warning_days  integer NOT NULL DEFAULT 30,
    authority     text,
    owner_name    text
);

INSERT INTO gate.learning_policy
  (policy_id, title, category, enforcement, applies_to, applies_value, cadence_months, warning_days, authority, owner_name)
VALUES
  ('CYBER_AWARE',  'Cybersecurity awareness',            'COMPLIANCE','DUE_DATE','ALL_STAFF',  NULL,        12, 30,'Corporate policy','IT'),
  ('HARASSMENT',   'Anti-harassment and respectful workplace','COMPLIANCE','DUE_DATE','ALL_STAFF',NULL,     24, 45,'State requirement','HR'),
  ('CODE_CONDUCT', 'Code of conduct attestation',        'COMPLIANCE','DUE_DATE','ALL_STAFF',  NULL,        12, 30,'Corporate policy','Legal'),
  ('RECORDS',      'Records retention and document handling','COMPLIANCE','DUE_DATE','DEPARTMENT','Legal',  12, 30,'Corporate policy','Legal'),
  ('SOX_CONTROLS', 'Internal controls over financial reporting','COMPLIANCE','DUE_DATE','DEPARTMENT','Finance',12,30,'Sarbanes-Oxley','Controller'),
  ('DATA_PRIVACY', 'Data privacy and personal information','COMPLIANCE','DUE_DATE','OFFICE',   NULL,        12, 30,'Corporate policy','Legal'),
  ('MGR_ESSENTIALS','People leadership essentials',       'ROLE',      'DUE_DATE','SUPERVISORY',NULL,       NULL,60,'Corporate policy','HR'),
  ('EXCEL_ADV',    'Advanced Excel for analysis',         'DEVELOPMENT','ELECTIVE','OFFICE',    NULL,       NULL,  0,NULL,'HR'),
  ('DATA_LIT',     'Data literacy fundamentals',          'DEVELOPMENT','ELECTIVE','ALL_STAFF', NULL,       NULL,  0,NULL,'HR'),
  ('PROJECT_MGMT', 'Project management foundations',       'DEVELOPMENT','ELECTIVE','OFFICE',    NULL,       NULL,  0,NULL,'HR')
ON CONFLICT (policy_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Corporate staff
-- ---------------------------------------------------------------------------
-- Headquarters had no roster, which made the office side invisible. Same table
-- as plant staff: one population, not two systems.

ALTER TABLE gate.hr_employee
    ADD COLUMN IF NOT EXISTS workforce text
        CHECK (workforce IN ('PLANT', 'OFFICE'));

UPDATE gate.hr_employee SET workforce = 'PLANT' WHERE workforce IS NULL;

INSERT INTO gate.hr_employee
  (id, name, descr, deptname, locationname, supvid, supvname,
   careerleveldescription, paystatus, regtemp, jobentrydate, loto_role, workforce, hazcom_trained_on)
VALUES
  ('50310','Lisa Chen',        'Financial Analyst',        'Finance',   'Columbus OH - Headquarters','50301','Marguerite Okonjo','Entry',              'A','R', DATE '2024-03-11','NONE','OFFICE', NULL),
  ('50311','Devon Marsh',      'Financial Analyst',        'Finance',   'Columbus OH - Headquarters','50301','Marguerite Okonjo','Entry',              'A','R', DATE '2022-08-01','NONE','OFFICE', NULL),
  ('50312','Aisha Rahimi',     'HR Business Partner',      'Human Resources','Columbus OH - Headquarters','50302','Peter Lindqvist','Entry',           'A','R', DATE '2023-01-23','NONE','OFFICE', NULL),
  ('50313','Grant Whitfield',  'Paralegal',                'Legal',     'Columbus OH - Headquarters','50303','Nadia Espinoza','Entry',                'A','R', DATE '2021-06-14','NONE','OFFICE', NULL),
  ('50314','Renata Oyelaran',  'Procurement Specialist',   'Purchasing','Columbus OH - Headquarters','50302','Peter Lindqvist','Entry',                'A','R', DATE '2024-09-30','NONE','OFFICE', NULL),
  ('50315','Emmett Kowalski',  'IT Systems Administrator', 'Information Technology','Columbus OH - Headquarters','50303','Nadia Espinoza','Entry',     'A','R', DATE '2022-02-07','NONE','OFFICE', NULL),
  ('50301','Marguerite Okonjo','Finance Manager',          'Finance',   'Columbus OH - Headquarters','50300','Harold Erie','Manager',              'A','R', DATE '2019-05-20','NONE','OFFICE', NULL),
  ('50302','Peter Lindqvist',  'Shared Services Manager',  'Human Resources','Columbus OH - Headquarters','50300','Harold Erie','Manager',         'A','R', DATE '2018-10-08','NONE','OFFICE', NULL),
  ('50303','Nadia Espinoza',   'Legal and IT Manager',     'Legal',     'Columbus OH - Headquarters','50300','Harold Erie','Manager',              'A','R', DATE '2020-04-02','NONE','OFFICE', NULL),
  ('50300','Harold Erie',  'Vice President',           'Corporate', 'Columbus OH - Headquarters',NULL,  NULL,             'Executive',             'A','R', DATE '2016-01-11','NONE','OFFICE', NULL)
ON CONFLICT (id) DO NOTHING;

-- Give headquarters a locationname so the roster and scope views resolve
UPDATE gate.site SET locationname = 'Columbus OH - Headquarters'
 WHERE site_id = 'HQ' AND locationname IS NULL;

INSERT INTO gate.viewer_scope (principal, scope_type, scope_value)
VALUES
  ('manager.okonjo',  'CREW', '50301'),
  ('manager.erie','SITE', 'Columbus OH - Headquarters')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Assignments
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS gate.learning_assignment (
    learning_assignment_id bigserial PRIMARY KEY,
    policy_id    text NOT NULL REFERENCES gate.learning_policy (policy_id),
    employee_id  text NOT NULL,
    assigned_on  date NOT NULL DEFAULT CURRENT_DATE,
    due_on       date,
    completed_on date,
    -- Elective enrolment is a choice rather than an assignment
    self_enrolled boolean NOT NULL DEFAULT false,
    score        numeric(5,2),
    evidence_ref text,
    UNIQUE (policy_id, employee_id, assigned_on)
);

-- Compliance obligations, assigned by policy rather than by hand
INSERT INTO gate.learning_assignment (policy_id, employee_id, assigned_on, due_on, completed_on, evidence_ref)
SELECT p.policy_id, e.id,
       assigned.d,
       assigned.d + interval '60 days',
       -- Most complete on time. A deliberate few do not, which is the point of
       -- having the view at all.
       CASE WHEN (abs(hashtext(e.id || p.policy_id)) % 10) < 7
            THEN assigned.d + ((abs(hashtext(e.id || p.policy_id)) % 55)) * interval '1 day' END,
       'LRN-' || p.policy_id || '-' || e.id
  FROM gate.learning_policy p
  CROSS JOIN LATERAL (
      -- Stagger across the year rather than assigning everything on one day, so
      -- the mix of overdue, due-soon and complete is realistic
      SELECT (CURRENT_DATE - ((abs(hashtext(p.policy_id)) % 300) + 20) * interval '1 day')::date AS d
  ) assigned
  JOIN gate.hr_employee e ON e.workforce = 'OFFICE' AND e.paystatus = 'A'
 WHERE p.category = 'COMPLIANCE'
   AND (p.applies_to = 'ALL_STAFF'
     OR (p.applies_to = 'OFFICE')
     OR (p.applies_to = 'DEPARTMENT' AND e.deptname = p.applies_value))
ON CONFLICT DO NOTHING;

-- Leadership essentials for managers
INSERT INTO gate.learning_assignment (policy_id, employee_id, assigned_on, due_on, completed_on, evidence_ref)
SELECT 'MGR_ESSENTIALS', e.id,
       CURRENT_DATE - interval '60 days', CURRENT_DATE + interval '30 days',
       CASE WHEN e.id IN ('50302','50303') THEN CURRENT_DATE - interval '20 days' END,
       'LRN-MGR_ESSENTIALS-' || e.id
  FROM gate.hr_employee e
 WHERE e.workforce = 'OFFICE' AND e.careerleveldescription IN ('Manager','Executive')
ON CONFLICT DO NOTHING;

-- Development, self-enrolled. Lisa Chen's Excel class is in progress.
INSERT INTO gate.learning_assignment
  (policy_id, employee_id, assigned_on, due_on, completed_on, self_enrolled, score, evidence_ref)
VALUES
  ('EXCEL_ADV',   '50310', CURRENT_DATE - interval '18 days', NULL, NULL,                              true, NULL, NULL),
  ('DATA_LIT',    '50310', CURRENT_DATE - interval '90 days', NULL, CURRENT_DATE - interval '40 days', true, 92.0,'LRN-DATA_LIT-50310'),
  ('EXCEL_ADV',   '50311', CURRENT_DATE - interval '200 days',NULL, CURRENT_DATE - interval '160 days',true, 88.5,'LRN-EXCEL_ADV-50311'),
  ('PROJECT_MGMT','50312', CURRENT_DATE - interval '30 days', NULL, NULL,                              true, NULL, NULL),
  ('DATA_LIT',    '50314', CURRENT_DATE - interval '12 days', NULL, NULL,                              true, NULL, NULL),
  ('EXCEL_ADV',   '50313', CURRENT_DATE - interval '400 days',NULL, CURRENT_DATE - interval '360 days',true, 79.0,'LRN-EXCEL_ADV-50313')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW gate.v_learning_assignment AS
SELECT
    a.learning_assignment_id,
    a.employee_id,
    e.name         AS employee_name,
    e.descr        AS job_description,
    e.deptname     AS department,
    e.locationname AS location,
    e.supvid       AS supervisor_id,
    e.supvname     AS supervisor_name,
    e.workforce,
    p.policy_id,
    p.title,
    p.category,
    p.enforcement,
    p.authority,
    p.owner_name,
    a.assigned_on,
    a.due_on,
    a.completed_on,
    a.self_enrolled,
    a.score,
    a.evidence_ref,
    CASE WHEN a.due_on IS NOT NULL THEN (a.due_on - CURRENT_DATE) END AS days_until_due,
    CASE
        WHEN a.completed_on IS NOT NULL                              THEN 'COMPLETE'
        WHEN a.due_on IS NULL                                        THEN 'IN_PROGRESS'
        WHEN a.due_on < CURRENT_DATE                                 THEN 'OVERDUE'
        WHEN a.due_on <= CURRENT_DATE + (p.warning_days || ' days')::interval THEN 'DUE_SOON'
        ELSE 'ON_TRACK'
    END AS status
FROM gate.learning_assignment a
JOIN gate.learning_policy p ON p.policy_id = a.policy_id
JOIN gate.hr_employee e     ON e.id = a.employee_id;

-- What a corporate manager asks: is my team current, and who is behind.
--
-- The plant equivalent asks about a work center. This asks about a reporting
-- line, which is why the two modules resolve requirements differently even
-- though they share everything else.
CREATE OR REPLACE VIEW gate.v_team_compliance AS
SELECT
    supervisor_id,
    supervisor_name,
    location,
    count(DISTINCT employee_id) AS team_size,
    count(*) FILTER (WHERE category = 'COMPLIANCE')                          AS compliance_assigned,
    count(*) FILTER (WHERE category = 'COMPLIANCE' AND status = 'COMPLETE')  AS compliance_complete,
    count(*) FILTER (WHERE category = 'COMPLIANCE' AND status = 'OVERDUE')   AS compliance_overdue,
    count(*) FILTER (WHERE category = 'COMPLIANCE' AND status = 'DUE_SOON')  AS compliance_due_soon,
    count(*) FILTER (WHERE category = 'DEVELOPMENT')                         AS development_taken,
    count(DISTINCT employee_id) FILTER (WHERE category = 'DEVELOPMENT')      AS people_developing,
    round(100.0 * count(*) FILTER (WHERE category = 'COMPLIANCE' AND status = 'COMPLETE')
          / NULLIF(count(*) FILTER (WHERE category = 'COMPLIANCE'), 0), 0)   AS compliance_pct
FROM gate.v_learning_assignment
WHERE supervisor_id IS NOT NULL
GROUP BY supervisor_id, supervisor_name, location;

-- Completion by policy, so an owner can see their own program
CREATE OR REPLACE VIEW gate.v_policy_status AS
SELECT
    p.policy_id,
    p.title,
    p.category,
    p.enforcement,
    p.authority,
    p.owner_name,
    p.cadence_months,
    count(a.*)                                              AS assigned,
    count(a.*) FILTER (WHERE a.completed_on IS NOT NULL)     AS completed,
    count(a.*) FILTER (WHERE a.completed_on IS NULL
                         AND a.due_on IS NOT NULL
                         AND a.due_on < CURRENT_DATE)        AS overdue,
    round(100.0 * count(a.*) FILTER (WHERE a.completed_on IS NOT NULL)
          / NULLIF(count(a.*), 0), 0)                        AS completion_pct
FROM gate.learning_policy p
LEFT JOIN gate.learning_assignment a ON a.policy_id = p.policy_id
GROUP BY p.policy_id, p.title, p.category, p.enforcement, p.authority, p.owner_name, p.cadence_months;
