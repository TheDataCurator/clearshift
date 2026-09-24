-- Qualification Gate — data model
--
-- Sits alongside an existing learning management schema. Nothing here replaces
-- certification, employee_certification, course or completion; this is the layer
-- that answers "is this person cleared for the work they are scheduled to do."
--
-- Three source tables are assumed to arrive as synced tables from the warehouse:
--   employee_current_workcenter_assignment  (UKG)   employee_id, work_center_id, work_center_desc, work_center_source, effective_date
--   employee_scheduled_workcenter_history   (UKG)   employee_id, work_date, scheduled_wc_*, actual_wc_*, has_transfer_on_date, wc_count_on_date, assignment_status
--   hr_employee                             (HCM)   id, name, descr, deptname, locationname, supvid, supvname, ...
--
-- Catalog and schema names are deliberately absent. Point the views at whatever
-- the synced tables end up being called.

CREATE SCHEMA IF NOT EXISTS gate;

-- ---------------------------------------------------------------------------
-- Risk classification
-- ---------------------------------------------------------------------------

-- The vocabulary of qualifications that gate work. Distinct from a course:
-- a course is how you earn it, this is what you hold.
CREATE TABLE IF NOT EXISTS gate.qualification (
    qualification_id      text PRIMARY KEY,
    name                  text NOT NULL,
    -- OSHA-cited work carries a regulatory obligation to produce evidence
    is_regulated          boolean NOT NULL DEFAULT false,
    regulation_reference  text,
    -- Whether a first performance must be supervised, and by whom
    requires_supervised_first_performance boolean NOT NULL DEFAULT false,
    -- Some qualifications travel with the person, some are authorized per site
    -- or per asset. Confined space entry is commonly permit-specific.
    scope                 text NOT NULL DEFAULT 'PORTABLE'
                          CHECK (scope IN ('PORTABLE', 'SITE_SPECIFIC', 'ASSET_SPECIFIC')),
    -- Null means it does not lapse
    validity_months       integer,
    -- Days before expiry that the renewal pipeline should surface someone
    renewal_warning_days  integer NOT NULL DEFAULT 60
);

-- What a given work center demands. The join key is the work center, because
-- that is what the schedule assigns and what the floor recognizes.
--
-- Effective-dated so that an audit can ask what was required at the time,
-- not what is required today.
CREATE TABLE IF NOT EXISTS gate.workcenter_requirement (
    requirement_id    bigserial PRIMARY KEY,
    work_center_id    text NOT NULL,
    qualification_id  text NOT NULL REFERENCES gate.qualification (qualification_id),
    effective_from    date NOT NULL,
    effective_to      date,
    CONSTRAINT workcenter_requirement_window CHECK (effective_to IS NULL OR effective_to > effective_from),
    -- One requirement per work center, credential and start date, so re-applying
    -- the seed is idempotent rather than doubling every row
    UNIQUE (work_center_id, qualification_id, effective_from)
);

CREATE INDEX IF NOT EXISTS workcenter_requirement_lookup
    ON gate.workcenter_requirement (work_center_id, effective_from DESC);

-- Some requirements attach to the job rather than the location. A welder needs
-- the welding qualification wherever they are standing.
CREATE TABLE IF NOT EXISTS gate.job_requirement (
    requirement_id    bigserial PRIMARY KEY,
    -- Matches hr_employee.descr
    job_description   text NOT NULL,
    qualification_id  text NOT NULL REFERENCES gate.qualification (qualification_id),
    effective_from    date NOT NULL,
    effective_to      date,
    CONSTRAINT job_requirement_window CHECK (effective_to IS NULL OR effective_to > effective_from),
    UNIQUE (job_description, qualification_id, effective_from)
);

CREATE INDEX IF NOT EXISTS job_requirement_lookup
    ON gate.job_requirement (job_description, effective_from DESC);

-- ---------------------------------------------------------------------------
-- What a person holds
-- ---------------------------------------------------------------------------

-- Temporal by construction. An audit asks "was this person qualified on the
-- fourteenth", which current-state storage cannot answer.
--
-- In a real deployment this is a view over the existing employee_certification
-- table rather than a second copy. It is materialized here so the demo can run
-- standalone.
CREATE TABLE IF NOT EXISTS gate.employee_qualification (
    employee_qualification_id bigserial PRIMARY KEY,
    employee_id        text NOT NULL,
    qualification_id   text NOT NULL REFERENCES gate.qualification (qualification_id),
    issued_on          date NOT NULL,
    expires_on         date,
    revoked_on         date,
    revoked_reason     text,
    -- Populated when scope is SITE_SPECIFIC or ASSET_SPECIFIC
    scoped_to          text,
    evidence_reference text,
    CONSTRAINT employee_qualification_window CHECK (expires_on IS NULL OR expires_on > issued_on),
    UNIQUE (employee_id, qualification_id, issued_on)
);

CREATE INDEX IF NOT EXISTS employee_qualification_lookup
    ON gate.employee_qualification (employee_id, qualification_id);

-- ---------------------------------------------------------------------------
-- Supervised first performance
-- ---------------------------------------------------------------------------

-- Holding a certificate is not the same as having done the work. The first
-- occasion carries the highest risk, so it is recorded separately and closes
-- only when a named supervisor signs it off.
--
-- This table is also the audit evidence that the control was applied.
CREATE TABLE IF NOT EXISTS gate.first_performance (
    first_performance_id bigserial PRIMARY KEY,
    employee_id       text NOT NULL,
    qualification_id  text NOT NULL REFERENCES gate.qualification (qualification_id),
    work_center_id    text NOT NULL,
    -- The shift that triggered it
    work_date         date NOT NULL,
    status            text NOT NULL DEFAULT 'PENDING'
                      CHECK (status IN ('PENDING', 'SUPERVISED', 'WAIVED')),
    supervised_by     text,
    supervised_on     date,
    waived_by         text,
    waiver_reason     text,
    UNIQUE (employee_id, qualification_id, work_center_id)
);

CREATE INDEX IF NOT EXISTS first_performance_open
    ON gate.first_performance (status, work_date);

-- ---------------------------------------------------------------------------
-- Alert acknowledgement
-- ---------------------------------------------------------------------------

-- An alert nobody answered is not a control. Acknowledgement is what makes it
-- one, and it is the record that proves someone was told.
CREATE TABLE IF NOT EXISTS gate.alert (
    alert_id        bigserial PRIMARY KEY,
    alert_type      text NOT NULL
                    CHECK (alert_type IN ('NOT_QUALIFIED', 'FIRST_PERFORMANCE', 'EXPIRING', 'UNPLANNED_TRANSFER')),
    employee_id     text NOT NULL,
    work_center_id  text,
    work_date       date,
    severity        text NOT NULL DEFAULT 'HIGH'
                    CHECK (severity IN ('HIGH', 'MEDIUM', 'LOW')),
    -- Supervisor of record at the time the alert was raised
    routed_to       text,
    raised_at       timestamptz NOT NULL DEFAULT now(),
    acknowledged_by text,
    acknowledged_at timestamptz,
    resolution      text
);

CREATE INDEX IF NOT EXISTS alert_open
    ON gate.alert (acknowledged_at, work_date);

-- ---------------------------------------------------------------------------
-- Site and supervisor scoping
-- ---------------------------------------------------------------------------

-- Site and supervisor are the access model, not a filter. A supervisor sees
-- their crew, a plant manager sees their site, safety sees everything.
-- Reading this table is also an audit trail of who looked at what.
CREATE TABLE IF NOT EXISTS gate.viewer_scope (
    viewer_scope_id bigserial PRIMARY KEY,
    principal       text NOT NULL,
    scope_type      text NOT NULL CHECK (scope_type IN ('CREW', 'SITE', 'ALL')),
    -- Supervisor id for CREW, locationname for SITE, null for ALL
    scope_value     text,
    UNIQUE (principal, scope_type, scope_value)
);
