-- Sites, and the workforce readiness view an executive asks for
--
-- Two additions beyond the shift-level gate:
--
--   1. Sites, so readiness can be seen across the network rather than one plant
--      at a time. Coordinates are public facility locations.
--
--   2. Coverage, and what one additional credential would unlock. Borrowed from
--      airline crew planning: rather than hiring, ask which existing person is
--      one certification away from covering a gap.

-- ---------------------------------------------------------------------------
-- Sites
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS gate.site (
    site_id      text PRIMARY KEY,
    -- Matches hr_employee.locationname so the join needs no mapping table
    locationname text UNIQUE,
    label        text NOT NULL,
    city         text,
    state        text,
    latitude     numeric(8,5),
    longitude    numeric(8,5),
    site_type    text NOT NULL DEFAULT 'PLANT'
                 CHECK (site_type IN ('HEADQUARTERS', 'PLANT', 'MAINTENANCE', 'TERMINAL')),
    -- Where a site sits in the phased rollout
    rollout_status text NOT NULL DEFAULT 'PLANNED'
                 CHECK (rollout_status IN ('LIVE', 'IN_FLIGHT', 'PLANNED')),
    rollout_on   date,
    headcount_estimate integer
);

-- Public facility locations. Coordinates are approximate city centroids, which
-- is the right precision for a network view.
INSERT INTO gate.site (site_id, locationname, label, city, state, latitude, longitude, site_type, rollout_status, rollout_on, headcount_estimate)
VALUES
  ('HQ',    NULL,                            'Columbus Headquarters','Columbus',      'OH',  39.96120, -82.99880, 'HEADQUARTERS', 'PLANNED',   NULL,             620),
  ('PEIL',  'Peoria IL - Plant 3081',   'Peoria',         'Peoria',  'IL',  40.69360, -89.58900, 'PLANT',        'IN_FLIGHT', DATE '2026-08-31', 340),
  ('GRMI',  'Grand Rapids MI - Plant 2401',      'Grand Rapids',            'Grand Rapids',     'MI',  42.96340, -85.66810, 'PLANT',        'PLANNED',   DATE '2026-09-14', 410),
  ('AUCO',  'Aurora CO - Plant 7619',     'Aurora',           'Aurora',    'CO',  39.72940, -104.83190, 'MAINTENANCE',  'PLANNED',   DATE '2026-09-28', 285),
  ('ROMN',  'Rochester MN - Plant 7617',        'Rochester',              'Rochester',       'MN',  44.01210, -92.48020, 'PLANT',        'PLANNED',   DATE '2026-09-28', 300),
  ('ERPA',  'Erie PA - Plant 7770',       'Erie',             'Erie',      'PA',  42.12920, -80.08510, 'PLANT',        'PLANNED',   DATE '2026-10-12', 190),
  ('SPMO',  'Springfield MO - Plant 3502',       'Springfield',             'Springfield',      'MO',  37.20890, -93.29230, 'PLANT',        'PLANNED',   DATE '2026-10-12', 225),
  ('DBIA',  'Dubuque IA - Plant 7071',         'Dubuque',               'Dubuque',        'IA',  42.50060, -90.66460, 'PLANT',        'PLANNED',   DATE '2026-10-26', 160),
  ('TOOH',  'Toledo OH - Plant 6383', 'Toledo',       'Toledo','OH',  41.65280, -83.53790, 'PLANT',        'PLANNED',   DATE '2026-10-26', 175),
  ('BOID',  'Boise ID - Plant 2880',      'Boise',            'Boise',     'ID',  43.61500, -116.20230, 'PLANT',        'PLANNED',   DATE '2026-11-09', 140),
  ('WIKS',  'Wichita KS - Plant 7401',        'Wichita',              'Wichita',       'KS',  37.68720, -97.33010, 'PLANT',        'PLANNED',   DATE '2026-11-09', 205),
  ('LNNE',  'Lincoln NE - Plant 3701',   'Lincoln',         'Lincoln',  'NE',  40.81360, -96.70260, 'PLANT',        'PLANNED',   DATE '2026-11-23', 155),
  ('RENV',  'Reno NV - Plant 8401',    'Reno',          'Reno',   'NV',  39.52960, -119.81380,'PLANT',        'PLANNED',   DATE '2026-11-23', 130),
  ('ALNY',  'Albany NY - Plant 7738',         'Albany',               'Albany',        'NY',  42.65260, -73.75620, 'TERMINAL',     'PLANNED',   DATE '2026-12-07', 95),
  ('HAPA',  'Harrisburg PA - Plant 7500',        'Harrisburg',              'Harrisburg',       'PA',  40.27320, -76.88670, 'TERMINAL',     'PLANNED',   DATE '2026-12-07', 85)
ON CONFLICT (site_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Network readiness
-- ---------------------------------------------------------------------------
-- One row per site. This is the executive view: where the program has landed,
-- where it has not, and where the exposure sits today.
--
-- Sites not yet onboarded report no readiness rather than a false zero. A site
-- with no data is an unknown, not a clean bill of health, and the distinction
-- matters when the number is being read as assurance.

CREATE OR REPLACE VIEW gate.v_site_readiness AS
WITH roster AS (
    SELECT
        location,
        employee_id,
        bool_and(qualification_state IN ('CURRENT', 'EXPIRING')) AS fully_covered,
        bool_or(qualification_state IN ('MISSING','EXPIRED','REVOKED','OUT_OF_SCOPE')) AS has_gap
    FROM gate.v_site_roster
    WHERE is_regulated
    GROUP BY location, employee_id
),
agg AS (
    SELECT
        location,
        count(*)                                    AS people_assessed,
        count(*) FILTER (WHERE fully_covered)       AS people_covered,
        count(*) FILTER (WHERE has_gap)             AS people_with_gap
    FROM roster
    GROUP BY location
),
expiring AS (
    SELECT location, count(*) AS expiring_90
    FROM gate.v_renewal_pipeline
    GROUP BY location
)
SELECT
    s.site_id,
    s.label,
    s.city,
    s.state,
    s.latitude,
    s.longitude,
    s.site_type,
    s.rollout_status,
    s.rollout_on,
    s.headcount_estimate,
    a.people_assessed,
    a.people_covered,
    a.people_with_gap,
    COALESCE(x.expiring_90, 0) AS expiring_90,
    CASE WHEN a.people_assessed > 0
         THEN round(100.0 * a.people_covered / a.people_assessed, 0)
    END AS coverage_pct,
    CASE
        WHEN a.people_assessed IS NULL          THEN 'NOT_ONBOARDED'
        WHEN a.people_with_gap > 0              THEN 'ACTION_REQUIRED'
        WHEN COALESCE(x.expiring_90, 0) > 0     THEN 'WATCH'
        ELSE 'CLEAR'
    END AS readiness
FROM gate.site s
LEFT JOIN agg      a ON a.location = s.locationname
LEFT JOIN expiring x ON x.location = s.locationname;

-- ---------------------------------------------------------------------------
-- Coverage, and the credential that would relieve it
-- ---------------------------------------------------------------------------

-- How thin cover is for each regulated credential at each site. One qualified
-- person covering a credential is a single point of failure: absence, illness or
-- a lapsed renewal takes the capability to zero.
CREATE OR REPLACE VIEW gate.v_coverage AS
WITH demand AS (
    -- Credentials actually demanded at each site, via the work centers in use
    SELECT DISTINCT
        e.locationname AS location,
        wr.qualification_id
    FROM gate.employee_current_workcenter_assignment a
    JOIN gate.hr_employee e ON e.id = a.employee_id
    JOIN gate.workcenter_requirement wr
         ON wr.work_center_id = a.work_center_id
        AND (wr.effective_to IS NULL OR wr.effective_to > CURRENT_DATE)
),
supply AS (
    SELECT
        qs.employee_location AS location,
        qs.qualification_id,
        count(*) FILTER (WHERE qs.state IN ('CURRENT','EXPIRING')) AS qualified_now
    FROM gate.v_qualification_state qs
    GROUP BY qs.employee_location, qs.qualification_id
)
SELECT
    d.location,
    d.qualification_id,
    q.name          AS qualification_name,
    q.is_regulated,
    COALESCE(s.qualified_now, 0) AS qualified_now,
    CASE
        WHEN COALESCE(s.qualified_now, 0) = 0 THEN 'NO_COVER'
        WHEN COALESCE(s.qualified_now, 0) = 1 THEN 'SINGLE_POINT'
        WHEN COALESCE(s.qualified_now, 0) <= 3 THEN 'THIN'
        ELSE 'ADEQUATE'
    END AS cover_state
FROM demand d
JOIN gate.qualification q ON q.qualification_id = d.qualification_id
LEFT JOIN supply s ON s.location = d.location AND s.qualification_id = d.qualification_id;

-- Which existing person is one credential away from relieving a thin spot.
--
-- The premise, borrowed from airline crew planning: a coverage gap is often not
-- a hiring problem. Someone already on site may be a single certification away
-- from covering it, and training an existing employee is faster and cheaper than
-- recruiting.
--
-- Candidates are ranked by how ready they already are. Someone who holds the
-- prerequisite credentials and has worked adjacent equipment is a better bet
-- than someone starting from nothing.
CREATE OR REPLACE VIEW gate.v_credential_opportunity AS
WITH thin AS (
    SELECT * FROM gate.v_coverage
     WHERE cover_state IN ('NO_COVER', 'SINGLE_POINT', 'THIN')
       AND is_regulated
),
-- Everyone at the site who does not already hold the credential
candidate AS (
    SELECT
        t.location,
        t.qualification_id,
        t.qualification_name,
        t.qualified_now,
        t.cover_state,
        e.id   AS employee_id,
        e.name AS employee_name,
        e.descr AS job_description,
        e.deptname AS department,
        e.supvname AS supervisor_name,
        -- How many other regulated credentials they already hold current.
        -- A proxy for how readily they absorb another.
        (SELECT count(*) FROM gate.v_qualification_state qs
          WHERE qs.employee_id = e.id
            AND qs.is_regulated
            AND qs.state IN ('CURRENT','EXPIRING')) AS credentials_held,
        -- Whether they already work a center that demands it, which means the
        -- gap is blocking work they are otherwise positioned to do
        EXISTS (
            SELECT 1
            FROM gate.employee_current_workcenter_assignment a2
            JOIN gate.workcenter_requirement wr2 ON wr2.work_center_id = a2.work_center_id
            WHERE a2.employee_id = e.id
              AND wr2.qualification_id = t.qualification_id
        ) AS already_assigned_to_such_work,
        -- Whether this credential was previously revoked for this person.
        --
        -- Someone whose certification was withdrawn after a procedure violation
        -- may still be the right person to requalify, but that is a judgment a
        -- human makes with the fact in front of them. Surfacing a name without
        -- the history would let the tool quietly recommend the opposite of what
        -- safety intends.
        EXISTS (
            SELECT 1 FROM gate.employee_qualification eq3
             WHERE eq3.employee_id      = e.id
               AND eq3.qualification_id = t.qualification_id
               AND eq3.revoked_on IS NOT NULL
        ) AS previously_revoked,
        (SELECT eq4.revoked_reason FROM gate.employee_qualification eq4
          WHERE eq4.employee_id      = e.id
            AND eq4.qualification_id = t.qualification_id
            AND eq4.revoked_on IS NOT NULL
          ORDER BY eq4.revoked_on DESC LIMIT 1) AS revoked_reason,
        -- Whether the credential merely lapsed, which is a renewal rather than
        -- new training and therefore the cheapest route to cover
        EXISTS (
            SELECT 1 FROM gate.employee_qualification eq5
             WHERE eq5.employee_id      = e.id
               AND eq5.qualification_id = t.qualification_id
               AND eq5.revoked_on IS NULL
               AND eq5.expires_on IS NOT NULL
               AND eq5.expires_on <= CURRENT_DATE
        ) AS lapsed_only
    FROM thin t
    JOIN gate.hr_employee e ON e.locationname = t.location AND e.paystatus = 'A'
    WHERE NOT EXISTS (
        SELECT 1 FROM gate.employee_qualification eq
         WHERE eq.employee_id      = e.id
           AND eq.qualification_id = t.qualification_id
           AND eq.revoked_on IS NULL
           AND (eq.expires_on IS NULL OR eq.expires_on > CURRENT_DATE)
    )
)
SELECT
    location,
    qualification_id,
    qualification_name,
    qualified_now,
    cover_state,
    employee_id,
    employee_name,
    job_description,
    department,
    supervisor_name,
    credentials_held,
    already_assigned_to_such_work,
    previously_revoked,
    revoked_reason,
    lapsed_only,
    -- The cheapest route to cover, which is what a planner actually wants to know
    CASE
        WHEN lapsed_only        THEN 'RENEW'
        WHEN previously_revoked THEN 'REQUALIFY_AFTER_REVOCATION'
        ELSE 'TRAIN'
    END AS route,
    -- Readiness, highest first. A revoked credential is pushed down rather than
    -- hidden: the decision belongs to a person, but it should not be the default
    -- suggestion.
    (  CASE WHEN lapsed_only THEN 50 ELSE 0 END
     + CASE WHEN already_assigned_to_such_work THEN 40 ELSE 0 END
     + credentials_held * 10
     - CASE WHEN previously_revoked THEN 100 ELSE 0 END) AS readiness_score
FROM candidate
ORDER BY location, qualification_name, readiness_score DESC;

-- ---------------------------------------------------------------------------
-- Scheduled training
-- ---------------------------------------------------------------------------
-- Phase two of the rollout covers office and business staff, whose obligations
-- are real but not OSHA-cited. The same requirement-and-credential model handles
-- both: a welding requalification and a compliance course differ in content and
-- consequence, not in structure.
--
-- Modelling both from the start avoids a second system later.

CREATE TABLE IF NOT EXISTS gate.training_session (
    session_id       bigserial PRIMARY KEY,
    qualification_id text REFERENCES gate.qualification (qualification_id),
    -- Non-regulated courses have no credential attached
    title            text NOT NULL,
    audience         text NOT NULL DEFAULT 'PLANT'
                     CHECK (audience IN ('PLANT', 'OFFICE', 'ALL')),
    delivery         text NOT NULL DEFAULT 'IN_PERSON'
                     CHECK (delivery IN ('IN_PERSON', 'VIRTUAL', 'SELF_PACED')),
    site_id          text REFERENCES gate.site (site_id),
    starts_on        date NOT NULL,
    seats            integer NOT NULL DEFAULT 12,
    instructor       text
);

CREATE TABLE IF NOT EXISTS gate.training_enrolment (
    enrolment_id bigserial PRIMARY KEY,
    session_id   bigint NOT NULL REFERENCES gate.training_session (session_id),
    employee_id  text NOT NULL,
    status       text NOT NULL DEFAULT 'ENROLLED'
                 CHECK (status IN ('ENROLLED', 'WAITLIST', 'COMPLETED', 'NO_SHOW')),
    UNIQUE (session_id, employee_id)
);

INSERT INTO gate.training_session (qualification_id, title, audience, delivery, site_id, starts_on, seats, instructor)
VALUES
  ('BLAST_COATING', 'Abrasive Blast and Coating — initial certification', 'PLANT',  'IN_PERSON', 'PEIL', CURRENT_DATE + 6,  8,  'Contract trainer'),
  ('HOT_WORK',      'Hot Work and Welding — requalification',             'PLANT',  'IN_PERSON', 'PEIL', CURRENT_DATE + 9,  10, 'R. Vance'),
  ('CONFINED_SPACE','Confined Space Entry — initial certification',        'PLANT',  'IN_PERSON', 'PEIL', CURRENT_DATE + 13, 6,  'Safety team'),
  ('POWERED_TRUCK', 'Powered Industrial Truck — site authorization',       'PLANT',  'IN_PERSON', 'PEIL', CURRENT_DATE + 16, 12, 'C. Lindahl'),
  ('CRANE_SIGNAL',  'Crane and Hoist Signalling — refresher',              'PLANT',  'IN_PERSON', 'PEIL', CURRENT_DATE + 20, 10, 'Safety team'),
  ('FIRST_AID_CPR', 'First Aid and CPR',                                   'ALL',    'IN_PERSON', 'PEIL', CURRENT_DATE + 23, 20, 'Red Cross'),
  (NULL,            'Records retention and document handling',             'OFFICE', 'VIRTUAL',   'HQ',   CURRENT_DATE + 11, 60, 'Legal'),
  (NULL,            'Anti-harassment and respectful workplace',            'OFFICE', 'VIRTUAL',   'HQ',   CURRENT_DATE + 18, 80, 'HR'),
  (NULL,            'Cybersecurity awareness — annual',                    'ALL',    'SELF_PACED','HQ',   CURRENT_DATE + 25, 500,'IT'),
  (NULL,            'Contractor safety orientation for site visitors',     'OFFICE', 'IN_PERSON', 'PEIL', CURRENT_DATE + 28, 25, 'Safety team')
ON CONFLICT DO NOTHING;

-- What is scheduled, and whether it addresses a gap that already exists.
--
-- A session that closes a live gap is worth more than one that does not, so the
-- link is made explicit rather than left for a coordinator to work out.
CREATE OR REPLACE VIEW gate.v_upcoming_training AS
SELECT
    t.session_id,
    t.title,
    t.qualification_id,
    q.name           AS qualification_name,
    COALESCE(q.is_regulated, false) AS is_regulated,
    t.audience,
    t.delivery,
    s.label          AS site_label,
    s.locationname   AS location,
    t.starts_on,
    (t.starts_on - CURRENT_DATE) AS days_away,
    t.seats,
    t.instructor,
    (SELECT count(*) FROM gate.training_enrolment e
      WHERE e.session_id = t.session_id AND e.status IN ('ENROLLED','COMPLETED')) AS enrolled,
    -- People at this site who currently fail the requirement this session covers
    CASE WHEN t.qualification_id IS NULL THEN 0 ELSE (
        SELECT count(DISTINCT r.employee_id) FROM gate.v_site_roster r
         WHERE r.location = s.locationname
           AND r.qualification_id = t.qualification_id
           AND r.qualification_state NOT IN ('CURRENT','EXPIRING')
    ) END AS would_close_gaps,
    -- Whether the credential has no cover at all at this site
    CASE WHEN t.qualification_id IS NULL THEN false ELSE EXISTS (
        SELECT 1 FROM gate.v_coverage c
         WHERE c.location = s.locationname
           AND c.qualification_id = t.qualification_id
           AND c.cover_state IN ('NO_COVER','SINGLE_POINT')
    ) END AS relieves_thin_cover
FROM gate.training_session t
LEFT JOIN gate.qualification q ON q.qualification_id = t.qualification_id
LEFT JOIN gate.site s ON s.site_id = t.site_id
ORDER BY t.starts_on;
