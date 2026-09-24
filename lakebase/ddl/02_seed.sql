-- Qualification Gate — seed data
--
-- Facility names are real and public. Every person, identifier, qualification
-- record and schedule row below is invented. No production data is reproduced.

-- ---------------------------------------------------------------------------
-- Stand-ins for the three synced source tables
-- ---------------------------------------------------------------------------
-- Column names mirror the real synced tables so the views below transfer with
-- only the schema qualifier changed.

-- Column names and order follow the source HCM extract so the views transfer by
-- changing the schema qualifier alone.
--
-- Personal and compensation fields are declared but left unpopulated in the seed.
-- The gate does not read them. They are present so the table shape matches the
-- source and so a reviewer can see which fields are deliberately unused.
CREATE TABLE IF NOT EXISTS gate.hr_employee (
    id                     text PRIMARY KEY,
    name                   text NOT NULL,
    email                  text,
    regregion              text,
    company                text,
    companyname            text,
    servicelinecode        text,
    servicelinename        text,
    location               text,
    locationname           text,
    deptid                 text,
    deptname               text,
    supvid                 text,
    supvname               text,
    orgunitleader          text,
    descr                  text,          -- job title
    subfunction            text,
    careerlevel            text,
    careerleveldescription text,
    labortype              text,
    grade                  text,
    type                   text,
    paystatus              text,
    regtemp                text,
    fullpart               text,
    jobentrydate           date,
    lateststartdate        date,
    datelastincrease       date,
    -- Compensation: not read by anything here
    annualrt               numeric,
    monthlyrt              numeric,
    hrlyrate               numeric,
    -- Personal: not read by anything here
    city                   text,
    state                  text,
    postal                 text,
    gender                 text,
    birthdate              date,
    marstatus              text,
    militarystatus         text,
    -- Extract load metadata
    filename               text,
    filedate               date,
    reportingmonth         text,
    reportingmonthkey      integer,
    loaddate               date,
    eltslt                 text
);

CREATE TABLE IF NOT EXISTS gate.employee_current_workcenter_assignment (
    employee_id       text,
    work_center_id    text,
    work_center_desc  text,
    work_center_source text,
    effective_date    timestamptz
);

CREATE TABLE IF NOT EXISTS gate.employee_scheduled_workcenter_history (
    employee_id             text,
    work_date               date,
    scheduled_wc_code       text,
    scheduled_wc_value      text,
    scheduled_wc_desc       text,
    actual_wc_code          text,
    actual_wc_value         text,
    actual_wc_desc          text,
    -- Present for one-for-one parity with the source table even though the gate
    -- logic does not read them. A stand-in that drops columns is not a stand-in.
    scheduled_segment_count integer,
    scheduled_total_seconds bigint,
    scheduled_hours         numeric,
    worked_span_count       integer,
    worked_total_seconds    bigint,
    worked_hours            numeric,
    variance_hours          numeric,
    wc_count_on_date        integer,
    has_transfer_on_date    boolean,
    assignment_status       text
);

-- ---------------------------------------------------------------------------
-- Qualifications
-- ---------------------------------------------------------------------------

INSERT INTO gate.qualification (qualification_id, name, is_regulated, regulation_reference,
                                requires_supervised_first_performance, scope, validity_months, renewal_warning_days)
VALUES
  ('CONFINED_SPACE', 'Confined Space Entry',        true,  '29 CFR 1910.146', true,  'SITE_SPECIFIC',  12, 60),
  ('HOT_WORK',       'Hot Work / Welding',          true,  '29 CFR 1910.252', true,  'PORTABLE',       24, 60),
  ('POWERED_TRUCK',  'Powered Industrial Truck',    true,  '29 CFR 1910.178', true,  'SITE_SPECIFIC',  36, 90),
  ('LOTO',           'Lockout / Tagout',            true,  '29 CFR 1910.147', false, 'PORTABLE',       24, 60),
  ('RESPIRATOR',     'Respiratory Protection',      true,  '29 CFR 1910.134', false, 'PORTABLE',       12, 45),
  ('FALL_PROTECT',   'Fall Protection',             true,  '29 CFR 1926.503', true,  'PORTABLE',       24, 60),
  ('CRANE_SIGNAL',   'Crane and Hoist Signalling',  true,  '29 CFR 1910.179', true,  'SITE_SPECIFIC',  36, 90),
  ('FIRST_AID_CPR',  'First Aid and CPR',           false, NULL,              false, 'PORTABLE',       24, 60),
  ('BLAST_COATING',  'Abrasive Blast and Coating',  true,  '29 CFR 1910.94',  true,  'PORTABLE',       24, 60)
ON CONFLICT (qualification_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Work centers, and what each one demands
-- ---------------------------------------------------------------------------
-- Identifier pattern follows the structured form seen in the source system.

INSERT INTO gate.workcenter_requirement (work_center_id, qualification_id, effective_from)
VALUES
  -- Tank interior work: the confined space case
  ('14309011-000-0822-5608', 'CONFINED_SPACE', DATE '2024-01-01'),
  ('14309011-000-0822-5608', 'RESPIRATOR',     DATE '2024-01-01'),
  ('14309011-000-0822-5608', 'LOTO',           DATE '2024-01-01'),
  -- Welding bay
  ('14317061-000-0106-1061', 'HOT_WORK',       DATE '2024-01-01'),
  ('14317061-000-0106-1061', 'FALL_PROTECT',   DATE '2024-01-01'),
  -- Blast and paint
  ('14309011-000-0852-5608', 'BLAST_COATING',  DATE '2024-01-01'),
  ('14309011-000-0852-5608', 'RESPIRATOR',     DATE '2024-01-01'),
  -- Materials handling
  ('14308011-399-3019-19350', 'POWERED_TRUCK', DATE '2024-01-01'),
  -- Stockroom and shipping
  ('14317015-001-0026-516',  'POWERED_TRUCK',  DATE '2024-01-01'),
  -- Tooling and fixturing, with overhead lifts
  ('14308011-999-9019-19942', 'CRANE_SIGNAL',  DATE '2024-01-01'),
  ('14308011-999-9019-19942', 'LOTO',          DATE '2024-01-01')
ON CONFLICT DO NOTHING;

INSERT INTO gate.job_requirement (job_description, qualification_id, effective_from)
VALUES
  ('Welder',                    'HOT_WORK',      DATE '2024-01-01'),
  ('Mobile Equipment Operator', 'POWERED_TRUCK', DATE '2024-01-01'),
  ('Painter',                   'BLAST_COATING', DATE '2024-01-01')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
-- Invented names. Peoria is the pilot site; a second site is included so
-- the site-scoped views have something to separate.

INSERT INTO gate.hr_employee (id, name, descr, deptname, locationname, supvid, supvname,
                              careerleveldescription, paystatus, regtemp, jobentrydate)
VALUES
  -- Peoria, IL — pilot
  ('40118', 'Marcus Ellery',   'Welder',                    'Welding',            'Peoria IL - Plant 3081', '40101', 'Rosalind Vance', 'Entry',                  'A', 'R', DATE '2023-04-17'),
  ('40119', 'Danielle Okafor', 'Welder',                    'Welding',            'Peoria IL - Plant 3081', '40101', 'Rosalind Vance', 'Entry',                  'A', 'R', DATE '2022-09-06'),
  ('40120', 'Trent Boland',    'Welder',                    'Welding',            'Peoria IL - Plant 3081', '40101', 'Rosalind Vance', 'Entry',                  'A', 'R', DATE '2026-06-29'),
  ('40121', 'Priya Raman',     'Maintenance Technician',    'Maintenance & Repair','Peoria IL - Plant 3081', '40102', 'Curtis Lindahl', 'Entry',                  'A', 'R', DATE '2021-02-15'),
  ('40122', 'Hollis Nakamura', 'Mobile Equipment Operator', 'Material Control',   'Peoria IL - Plant 3081', '40102', 'Curtis Lindahl', 'Entry',                  'A', 'R', DATE '2024-11-04'),
  ('40123', 'Simone Adebayo',  'Painter',                   'Paint/Blast',        'Peoria IL - Plant 3081', '40103', 'Gerald Pruitt',  'Entry',                  'A', 'R', DATE '2023-08-21'),
  ('40124', 'Rafael Ibarra',   'Maintenance Technician',    'Fixtures & Tooling', 'Peoria IL - Plant 3081', '40103', 'Gerald Pruitt',  'Entry',                  'A', 'R', DATE '2020-05-11'),
  ('40125', 'Yvette Coleridge','Quality Inspector',         'Quality',            'Peoria IL - Plant 3081', '40103', 'Gerald Pruitt',  'Entry',                  'A', 'R', DATE '2022-01-24'),
  ('40101', 'Rosalind Vance',  'Production Supervisor',     'Welding',            'Peoria IL - Plant 3081', '40100', 'Dean Whitlock',  'Operations Supervisor',  'A', 'R', DATE '2019-03-04'),
  ('40102', 'Curtis Lindahl',  'Production Supervisor',     'Maintenance & Repair','Peoria IL - Plant 3081','40100', 'Dean Whitlock',  'Operations Supervisor',  'A', 'R', DATE '2018-07-16'),
  ('40103', 'Gerald Pruitt',   'Production Supervisor',     'Paint/Blast',        'Peoria IL - Plant 3081', '40100', 'Dean Whitlock',  'Operations Supervisor',  'A', 'R', DATE '2017-11-27'),
  ('40100', 'Dean Whitlock',   'Plant Manager',             'Operations',         'Peoria IL - Plant 3081', NULL,    NULL,             'Plant Leadership',       'A', 'R', DATE '2015-06-01'),
  -- Grand Rapids, MI — second site
  ('40210', 'Aurelio Sandoval','Welder',                    'Welding',            'Grand Rapids MI - Plant 2401',    '40201', 'Marguerite Ihde','Entry',                  'A', 'R', DATE '2021-10-18'),
  ('40211', 'Bettina Krogh',   'Mobile Equipment Operator', 'Material Control',   'Grand Rapids MI - Plant 2401',    '40201', 'Marguerite Ihde','Entry',                  'A', 'R', DATE '2023-03-27'),
  ('40201', 'Marguerite Ihde', 'Production Supervisor',     'Welding',            'Grand Rapids MI - Plant 2401',    NULL,    NULL,             'Operations Supervisor',  'A', 'R', DATE '2016-09-12')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Current work center assignment
-- ---------------------------------------------------------------------------

INSERT INTO gate.employee_current_workcenter_assignment (employee_id, work_center_id, work_center_desc, work_center_source, effective_date)
VALUES
  ('40118', '14317061-000-0106-1061',  'PLASMA TABLE',                 'SCHEDULE', now() - interval '120 days'),
  ('40119', '14317061-000-0106-1061',  'PLASMA TABLE',                 'SCHEDULE', now() - interval '300 days'),
  ('40120', '14317061-000-0106-1061',  'PLASMA TABLE',                 'SCHEDULE', now() - interval '20 days'),
  ('40121', '14308011-999-9019-19942', 'INDIRECT - TOOLING - FIXTURING','SCHEDULE', now() - interval '400 days'),
  ('40122', '14317015-001-0026-516',   'STOCKROOM- SHIPPING- RECEIVING','SCHEDULE', now() - interval '200 days'),
  ('40123', '14309011-000-0852-5608',  'SPIN DEPT',                    'SCHEDULE', now() - interval '250 days'),
  ('40124', '14308011-999-9019-19942', 'INDIRECT - TOOLING - FIXTURING','SCHEDULE', now() - interval '500 days'),
  ('40125', '14317015-001-0026-516',   'STOCKROOM- SHIPPING- RECEIVING','SCHEDULE', now() - interval '180 days'),
  ('40210', '14317061-000-0106-1061',  'PLASMA TABLE',                 'SCHEDULE', now() - interval '330 days'),
  ('40211', '14308011-399-3019-19350', 'BAY OPERATIONS - MATERIALS',   'SCHEDULE', now() - interval '150 days')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Qualifications held
-- ---------------------------------------------------------------------------
-- Deliberately mixed so the gate has something to catch: current, expiring,
-- lapsed, revoked, wrong-site, and absent.

INSERT INTO gate.employee_qualification (employee_id, qualification_id, issued_on, expires_on, revoked_on, revoked_reason, scoped_to, evidence_reference)
VALUES
  -- Marcus Ellery: welding current, no confined space at all
  ('40118', 'HOT_WORK',      CURRENT_DATE - interval '400 days', CURRENT_DATE + interval '330 days', NULL, NULL, NULL, 'CERT-40118-HW'),
  ('40118', 'FALL_PROTECT',  CURRENT_DATE - interval '380 days', CURRENT_DATE + interval '350 days', NULL, NULL, NULL, 'CERT-40118-FP'),
  ('40118', 'LOTO',          CURRENT_DATE - interval '200 days', CURRENT_DATE + interval '530 days', NULL, NULL, NULL, 'CERT-40118-LO'),

  -- Danielle Okafor: confined space certified at Peoria, first performance not yet done
  ('40119', 'HOT_WORK',      CURRENT_DATE - interval '600 days', CURRENT_DATE + interval '130 days', NULL, NULL, NULL, 'CERT-40119-HW'),
  ('40119', 'CONFINED_SPACE',CURRENT_DATE - interval '9 days',   CURRENT_DATE + interval '356 days', NULL, NULL, 'Peoria IL - Plant 3081', 'CERT-40119-CS'),
  ('40119', 'RESPIRATOR',    CURRENT_DATE - interval '30 days',  CURRENT_DATE + interval '335 days', NULL, NULL, NULL, 'CERT-40119-RE'),
  ('40119', 'LOTO',          CURRENT_DATE - interval '300 days', CURRENT_DATE + interval '430 days', NULL, NULL, NULL, 'CERT-40119-LO'),
  ('40119', 'FALL_PROTECT',  CURRENT_DATE - interval '250 days', CURRENT_DATE + interval '480 days', NULL, NULL, NULL, 'CERT-40119-FP'),

  -- Trent Boland: new hire, welding qualification lapsed 12 days ago
  ('40120', 'HOT_WORK',      CURRENT_DATE - interval '742 days', CURRENT_DATE - interval '12 days', NULL, NULL, NULL, 'CERT-40120-HW'),
  ('40120', 'FALL_PROTECT',  CURRENT_DATE - interval '40 days',  CURRENT_DATE + interval '690 days', NULL, NULL, NULL, 'CERT-40120-FP'),

  -- Priya Raman: crane signalling expiring inside the warning window
  ('40121', 'CRANE_SIGNAL',  CURRENT_DATE - interval '1050 days',CURRENT_DATE + interval '45 days', NULL, NULL, 'Peoria IL - Plant 3081', 'CERT-40121-CR'),
  ('40121', 'LOTO',          CURRENT_DATE - interval '100 days', CURRENT_DATE + interval '630 days', NULL, NULL, NULL, 'CERT-40121-LO'),
  ('40121', 'CONFINED_SPACE',CURRENT_DATE - interval '200 days', CURRENT_DATE + interval '165 days', NULL, NULL, 'Peoria IL - Plant 3081', 'CERT-40121-CS'),
  ('40121', 'RESPIRATOR',    CURRENT_DATE - interval '120 days', CURRENT_DATE + interval '245 days', NULL, NULL, NULL, 'CERT-40121-RE'),

  -- Hollis Nakamura: forklift certified for Grand Rapids only, now works Peoria
  ('40122', 'POWERED_TRUCK', CURRENT_DATE - interval '500 days', CURRENT_DATE + interval '595 days', NULL, NULL, 'Grand Rapids MI - Plant 2401', 'CERT-40122-PT'),

  -- Simone Adebayo: blast and coating revoked
  ('40123', 'BLAST_COATING', CURRENT_DATE - interval '300 days', CURRENT_DATE + interval '430 days', CURRENT_DATE - interval '20 days', 'Procedure violation, pending requalification', NULL, 'CERT-40123-BC'),
  ('40123', 'RESPIRATOR',    CURRENT_DATE - interval '60 days',  CURRENT_DATE + interval '305 days', NULL, NULL, NULL, 'CERT-40123-RE'),

  -- Rafael Ibarra: fully current
  ('40124', 'CRANE_SIGNAL',  CURRENT_DATE - interval '200 days', CURRENT_DATE + interval '895 days', NULL, NULL, 'Peoria IL - Plant 3081', 'CERT-40124-CR'),
  ('40124', 'LOTO',          CURRENT_DATE - interval '150 days', CURRENT_DATE + interval '580 days', NULL, NULL, NULL, 'CERT-40124-LO'),
  ('40124', 'FIRST_AID_CPR', CURRENT_DATE - interval '90 days',  CURRENT_DATE + interval '640 days', NULL, NULL, NULL, 'CERT-40124-FA'),

  -- Yvette Coleridge: forklift current
  ('40125', 'POWERED_TRUCK', CURRENT_DATE - interval '400 days', CURRENT_DATE + interval '695 days', NULL, NULL, 'Peoria IL - Plant 3081', 'CERT-40125-PT'),

  -- Grand Rapids
  ('40210', 'HOT_WORK',      CURRENT_DATE - interval '500 days', CURRENT_DATE + interval '230 days', NULL, NULL, NULL, 'CERT-40210-HW'),
  ('40210', 'FALL_PROTECT',  CURRENT_DATE - interval '400 days', CURRENT_DATE + interval '330 days', NULL, NULL, NULL, 'CERT-40210-FP'),
  ('40211', 'POWERED_TRUCK', CURRENT_DATE - interval '300 days', CURRENT_DATE + interval '795 days', NULL, NULL, 'Grand Rapids MI - Plant 2401', 'CERT-40211-PT')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Schedule history, including the forward schedule
-- ---------------------------------------------------------------------------
-- Past rows establish where each person has worked before, which is what makes
-- a first appearance detectable. Future rows are what the alert reads.

-- Established history: each person repeatedly in their usual work center
INSERT INTO gate.employee_scheduled_workcenter_history
  (employee_id, work_date, scheduled_wc_code, scheduled_wc_value, scheduled_wc_desc,
   actual_wc_code, actual_wc_value, actual_wc_desc,
   scheduled_hours, worked_hours, variance_hours, wc_count_on_date, has_transfer_on_date, assignment_status)
SELECT
  a.employee_id,
  (CURRENT_DATE - (d || ' days')::interval)::date,
  a.work_center_id, a.work_center_id, a.work_center_desc,
  a.work_center_id, a.work_center_id, a.work_center_desc,
  8.0, 8.0, 0.0, 1, false, 'ACTIVE'
FROM gate.employee_current_workcenter_assignment a
CROSS JOIN generate_series(3, 45) AS d
WHERE EXTRACT(dow FROM (CURRENT_DATE - (d || ' days')::interval)) BETWEEN 1 AND 5;

-- Forward schedule: tomorrow. This is what the pre-shift alert reads.
INSERT INTO gate.employee_scheduled_workcenter_history
  (employee_id, work_date, scheduled_wc_code, scheduled_wc_value, scheduled_wc_desc,
   actual_wc_code, actual_wc_value, actual_wc_desc,
   scheduled_hours, worked_hours, variance_hours, wc_count_on_date, has_transfer_on_date, assignment_status)
VALUES
  -- Marcus Ellery into tank interior work. Never been there, holds no confined space qualification.
  ('40118', CURRENT_DATE + 1, '14309011-000-0822-5608', '14309011-000-0822-5608', 'BURN DEPT',
   NULL, NULL, NULL, 8.0, NULL, NULL, 1, false, 'SCHEDULED'),

  -- Danielle Okafor into tank interior work. Qualified, correctly scoped, but this is her first time.
  ('40119', CURRENT_DATE + 1, '14309011-000-0822-5608', '14309011-000-0822-5608', 'BURN DEPT',
   NULL, NULL, NULL, 8.0, NULL, NULL, 1, false, 'SCHEDULED'),

  -- Trent Boland in his usual welding bay, but his welding qualification lapsed
  ('40120', CURRENT_DATE + 1, '14317061-000-0106-1061', '14317061-000-0106-1061', 'PLASMA TABLE',
   NULL, NULL, NULL, 8.0, NULL, NULL, 1, false, 'SCHEDULED'),

  -- Hollis Nakamura onto materials handling. Forklift qualification is scoped to a different site.
  ('40122', CURRENT_DATE + 1, '14308011-399-3019-19350', '14308011-399-3019-19350', 'BAY OPERATIONS - MATERIALS',
   NULL, NULL, NULL, 8.0, NULL, NULL, 1, false, 'SCHEDULED'),

  -- Simone Adebayo in blast and coating with a revoked qualification
  ('40123', CURRENT_DATE + 1, '14309011-000-0852-5608', '14309011-000-0852-5608', 'SPIN DEPT',
   NULL, NULL, NULL, 8.0, NULL, NULL, 1, false, 'SCHEDULED'),

  -- Rafael Ibarra, fully current, in his usual work center. Should not alert.
  ('40124', CURRENT_DATE + 1, '14308011-999-9019-19942', '14308011-999-9019-19942', 'INDIRECT - TOOLING - FIXTURING',
   NULL, NULL, NULL, 8.0, NULL, NULL, 1, false, 'SCHEDULED'),

  -- Yvette Coleridge, current, usual work center. Should not alert.
  ('40125', CURRENT_DATE + 1, '14317015-001-0026-516', '14317015-001-0026-516', 'STOCKROOM- SHIPPING- RECEIVING',
   NULL, NULL, NULL, 8.0, NULL, NULL, 1, false, 'SCHEDULED');

-- Yesterday: an unplanned mid-shift transfer that a clock-in gate would have cleared.
-- Scheduled into welding, actually worked tank interior.
INSERT INTO gate.employee_scheduled_workcenter_history
  (employee_id, work_date, scheduled_wc_code, scheduled_wc_value, scheduled_wc_desc,
   actual_wc_code, actual_wc_value, actual_wc_desc,
   scheduled_hours, worked_hours, variance_hours, wc_count_on_date, has_transfer_on_date, assignment_status)
VALUES
  ('40118', CURRENT_DATE - 1, '14317061-000-0106-1061', '14317061-000-0106-1061', 'PLASMA TABLE',
   '14309011-000-0822-5608', '14309011-000-0822-5608', 'BURN DEPT',
   8.0, 8.5, 0.5, 2, true, 'ACTIVE');

-- ---------------------------------------------------------------------------
-- Viewer scopes
-- ---------------------------------------------------------------------------

INSERT INTO gate.viewer_scope (principal, scope_type, scope_value)
VALUES
  ('supervisor.vance',   'CREW', '40101'),
  ('supervisor.lindahl', 'CREW', '40102'),
  ('supervisor.pruitt',  'CREW', '40103'),
  ('manager.whitlock',   'SITE', 'Peoria IL - Plant 3081'),
  ('manager.ihde',       'SITE', 'Grand Rapids MI - Plant 2401'),
  ('safety.corporate',   'ALL',  NULL)
ON CONFLICT DO NOTHING;
