-- Credentialing requests
--
-- Identifying a candidate is not an action. This records the request that goes to
-- their supervisor, so a coverage gap can be closed rather than only observed.
--
-- Recorded rather than sent: the request is the artifact, and it is auditable.
-- Whether it leaves as mail, a Teams message or a ticket is a delivery detail.

CREATE TABLE IF NOT EXISTS gate.credentialing_request (
    credentialing_request_id bigserial PRIMARY KEY,
    employee_id      text NOT NULL,
    qualification_id text NOT NULL REFERENCES gate.qualification (qualification_id),
    location         text,
    -- Who the request is addressed to, and who raised it
    supervisor_name  text,
    requested_by     text NOT NULL,
    requested_at     timestamptz NOT NULL DEFAULT now(),
    -- The coverage position at the time of asking, held so the request still
    -- reads correctly once the gap has moved on
    qualified_at_request integer,
    cover_state_at_request text,
    route            text,
    note             text,
    status           text NOT NULL DEFAULT 'SENT'
                     CHECK (status IN ('SENT', 'ACKNOWLEDGED', 'SCHEDULED', 'DECLINED')),
    UNIQUE (employee_id, qualification_id, requested_at)
);

CREATE INDEX IF NOT EXISTS credentialing_request_lookup
    ON gate.credentialing_request (employee_id, qualification_id);

CREATE OR REPLACE VIEW gate.v_credentialing_request AS
SELECT
    r.credentialing_request_id,
    r.employee_id,
    e.name         AS employee_name,
    e.descr        AS job_description,
    e.deptname     AS department,
    e.locationname AS location,
    e.supvid       AS supervisor_id,
    r.supervisor_name,
    r.qualification_id,
    q.name         AS qualification_name,
    q.is_regulated,
    r.requested_by,
    r.requested_at,
    r.requested_at::date AS requested_on,
    r.qualified_at_request,
    r.cover_state_at_request,
    r.route,
    r.note,
    r.status
FROM gate.credentialing_request r
JOIN gate.hr_employee e   ON e.id = r.employee_id
JOIN gate.qualification q ON q.qualification_id = r.qualification_id;

-- ---------------------------------------------------------------------------
-- Terminology
-- ---------------------------------------------------------------------------
-- The everyday word for a credential and its regulatory name often share nothing:
-- a forklift is a powered industrial truck, welding is hot work. Holding the
-- mapping as data rather than in application code lets it be shown to a reader
-- and corrected by someone who knows the plant vocabulary.

CREATE TABLE IF NOT EXISTS gate.terminology (
    terminology_id   bigserial PRIMARY KEY,
    qualification_id text NOT NULL REFERENCES gate.qualification (qualification_id),
    term             text NOT NULL,
    kind             text NOT NULL DEFAULT 'COMMON'
                     CHECK (kind IN ('COMMON', 'FORMAL', 'ABBREVIATION', 'EQUIPMENT')),
    UNIQUE (qualification_id, term)
);

INSERT INTO gate.terminology (qualification_id, term, kind) VALUES
  ('POWERED_TRUCK','forklift','COMMON'),
  ('POWERED_TRUCK','fork lift','COMMON'),
  ('POWERED_TRUCK','lift truck','COMMON'),
  ('POWERED_TRUCK','PIT','ABBREVIATION'),
  ('POWERED_TRUCK','powered industrial truck','FORMAL'),
  ('HOT_WORK','welding','COMMON'),
  ('HOT_WORK','weld','COMMON'),
  ('HOT_WORK','cutting','COMMON'),
  ('HOT_WORK','hot work','FORMAL'),
  ('CONFINED_SPACE','tank entry','COMMON'),
  ('CONFINED_SPACE','vessel entry','COMMON'),
  ('CONFINED_SPACE','confined space','FORMAL'),
  ('CONFINED_SPACE','permit-required confined space','FORMAL'),
  ('LOTO','lockout','COMMON'),
  ('LOTO','tagout','COMMON'),
  ('LOTO','LOTO','ABBREVIATION'),
  ('LOTO','energy control','FORMAL'),
  ('RESPIRATOR','respirator','COMMON'),
  ('RESPIRATOR','respiratory protection','FORMAL'),
  ('FALL_PROTECT','fall protection','FORMAL'),
  ('FALL_PROTECT','harness','EQUIPMENT'),
  ('FALL_PROTECT','tie-off','COMMON'),
  ('CRANE_SIGNAL','crane','COMMON'),
  ('CRANE_SIGNAL','hoist','COMMON'),
  ('CRANE_SIGNAL','rigging','COMMON'),
  ('CRANE_SIGNAL','crane and hoist signalling','FORMAL'),
  ('BLAST_COATING','blast','COMMON'),
  ('BLAST_COATING','sandblasting','COMMON'),
  ('BLAST_COATING','painting','COMMON'),
  ('BLAST_COATING','abrasive blast and coating','FORMAL'),
  ('FIRST_AID_CPR','first aid','COMMON'),
  ('FIRST_AID_CPR','CPR','ABBREVIATION')
ON CONFLICT (qualification_id, term) DO NOTHING;

-- Everything a reader needs to follow the logic: the credential, the standard it
-- derives from, how long it lasts, whether a supervised first performance and a
-- recurring practical evaluation apply, and the words people use for it.
CREATE OR REPLACE VIEW gate.v_glossary AS
SELECT
    q.qualification_id,
    q.name,
    q.is_regulated,
    q.regulation_reference,
    q.scope,
    q.validity_months,
    q.renewal_warning_days,
    q.requires_supervised_first_performance,
    q.practical_evaluation_months,
    q.requires_competent_person,
    (SELECT string_agg(t.term, ', ' ORDER BY t.term)
       FROM gate.terminology t
      WHERE t.qualification_id = q.qualification_id AND t.kind = 'COMMON') AS common_terms,
    (SELECT string_agg(t.term, ', ' ORDER BY t.term)
       FROM gate.terminology t
      WHERE t.qualification_id = q.qualification_id AND t.kind = 'ABBREVIATION') AS abbreviations,
    (SELECT count(*) FROM gate.workcenter_requirement wr
      WHERE wr.qualification_id = q.qualification_id
        AND (wr.effective_to IS NULL OR wr.effective_to > CURRENT_DATE)) AS work_centers_requiring,
    (SELECT count(*) FROM gate.job_requirement jr
      WHERE jr.qualification_id = q.qualification_id
        AND (jr.effective_to IS NULL OR jr.effective_to > CURRENT_DATE)) AS jobs_requiring
FROM gate.qualification q
ORDER BY q.is_regulated DESC, q.name;
