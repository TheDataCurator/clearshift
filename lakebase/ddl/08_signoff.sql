-- Worker sign-off and training acknowledgment
--
-- The piece that closes the audit kit. A completion record says the system
-- believes someone was trained. An acknowledgment says the person states they
-- received it, understood it, and knows what they are responsible for.
--
-- The distinction matters under audit. "Our system shows he completed it" is
-- weaker than a signed statement naming the trainer, the date and the content.
-- Several OSHA standards expect the employer to certify training was
-- accomplished, and a signature is how that certification is usually evidenced.
--
-- Written as an append-only record. An acknowledgment that can be edited after
-- the fact is not evidence, so corrections are made by superseding rather than
-- by update.

CREATE TABLE IF NOT EXISTS gate.acknowledgment (
    acknowledgment_id bigserial PRIMARY KEY,
    employee_id     text NOT NULL,
    -- Exactly one of these three anchors the acknowledgment
    qualification_id text REFERENCES gate.qualification (qualification_id),
    policy_id        text REFERENCES gate.learning_policy (policy_id),
    session_id       bigint REFERENCES gate.training_session (session_id),
    subject          text NOT NULL,
    kind             text NOT NULL CHECK (kind IN
                     ('TRAINING_RECEIPT', 'POLICY_ATTESTATION', 'HAZARD_BRIEFING',
                      'SUPERVISED_FIRST_PERFORMANCE', 'REQUALIFICATION')),
    -- What the person is stating. Held verbatim so the record shows what was
    -- actually agreed to, not what today's template happens to say.
    statement       text NOT NULL,
    signed_on       timestamptz NOT NULL DEFAULT now(),
    -- How the signature was captured, since an auditor will ask
    method          text NOT NULL DEFAULT 'IN_APP'
                    CHECK (method IN ('IN_APP', 'WET_SIGNATURE', 'KIOSK', 'SUPERVISOR_PROXY')),
    signed_by_name  text NOT NULL,
    -- A proxy signature is weaker evidence and must be visibly so
    proxy_for       text,
    trainer_name    text,
    trainer_id      text,
    location        text,
    work_center_id  text,
    document_ref    text,
    -- Corrections supersede rather than overwrite
    superseded_by   bigint REFERENCES gate.acknowledgment (acknowledgment_id),
    -- The document reference is the natural key an auditor cites
    UNIQUE (document_ref),
    CONSTRAINT acknowledgment_has_one_anchor CHECK (
        (qualification_id IS NOT NULL)::int
      + (policy_id        IS NOT NULL)::int
      + (session_id       IS NOT NULL)::int <= 1
    )
);

CREATE INDEX IF NOT EXISTS acknowledgment_lookup
    ON gate.acknowledgment (employee_id, signed_on DESC);

-- Standard statements. Held as data rather than in application code so the
-- wording an employee agreed to is recoverable years later.
CREATE TABLE IF NOT EXISTS gate.acknowledgment_template (
    template_id text PRIMARY KEY,
    kind        text NOT NULL,
    statement   text NOT NULL,
    version     text NOT NULL DEFAULT '1.0'
);

INSERT INTO gate.acknowledgment_template (template_id, kind, statement, version) VALUES
  ('TRAINING_RECEIPT', 'TRAINING_RECEIPT',
   'I confirm that I received and understood the training identified above, that I had the '
   || 'opportunity to ask questions, and that I know which tasks it authorizes me to perform.', '1.0'),
  ('POLICY_ATTESTATION', 'POLICY_ATTESTATION',
   'I confirm that I have read the policy identified above and understand my responsibilities '
   || 'under it.', '1.0'),
  ('HAZARD_BRIEFING', 'HAZARD_BRIEFING',
   'I confirm that the hazards of this work center and the controls in place were explained to '
   || 'me, and that I know how to report an unsafe condition.', '1.0'),
  ('SUPERVISED_FIRST_PERFORMANCE', 'SUPERVISED_FIRST_PERFORMANCE',
   'I confirm that this was my first time performing this work, that a qualified supervisor was '
   || 'present throughout, and that I was able to raise concerns during the task.', '1.0'),
  ('REQUALIFICATION', 'REQUALIFICATION',
   'I confirm that I completed requalification for the credential identified above and '
   || 'understand the reason it was required.', '1.0')
ON CONFLICT (template_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Seed
-- ---------------------------------------------------------------------------

INSERT INTO gate.acknowledgment
  (employee_id, qualification_id, subject, kind, statement, signed_on, method,
   signed_by_name, trainer_name, trainer_id, location, work_center_id, document_ref)
SELECT
    eq.employee_id,
    eq.qualification_id,
    q.name || ' — initial certification',
    'TRAINING_RECEIPT',
    (SELECT statement FROM gate.acknowledgment_template WHERE template_id = 'TRAINING_RECEIPT'),
    eq.issued_on + interval '9 hours',
    'IN_APP',
    e.name,
    CASE WHEN q.qualification_id IN ('CONFINED_SPACE','RESPIRATOR') THEN 'Safety team'
         WHEN q.qualification_id = 'POWERED_TRUCK' THEN 'C. Lindahl'
         ELSE 'R. Vance' END,
    'OT-22841',
    e.locationname,
    NULL,
    'ACK-' || eq.qualification_id || '-' || eq.employee_id
  FROM gate.employee_qualification eq
  JOIN gate.qualification q ON q.qualification_id = eq.qualification_id
  JOIN gate.hr_employee e   ON e.id = eq.employee_id
 WHERE eq.revoked_on IS NULL
   -- One person deliberately has a credential with no signed receipt, which is
   -- the gap this table exists to surface.
   AND NOT (eq.employee_id = '40122' AND eq.qualification_id = 'POWERED_TRUCK')
ON CONFLICT DO NOTHING;

-- A supervised first performance, signed by both parties
INSERT INTO gate.acknowledgment
  (employee_id, qualification_id, subject, kind, statement, signed_on, method,
   signed_by_name, trainer_name, location, work_center_id, document_ref)
VALUES
  ('40121','CONFINED_SPACE','Confined Space Entry — first supervised entry, tank interior',
   'SUPERVISED_FIRST_PERFORMANCE',
   (SELECT statement FROM gate.acknowledgment_template WHERE template_id = 'SUPERVISED_FIRST_PERFORMANCE'),
   now() - interval '160 days','IN_APP','Priya Raman','C. Lindahl',
   'Peoria IL - Plant 3081','14309011-000-0822-5608','ACK-CS-FP-40121'),
  -- A proxy signature, which is weaker evidence and shown as such
  ('40124','CRANE_SIGNAL','Crane and Hoist Signalling — refresher',
   'TRAINING_RECEIPT',
   (SELECT statement FROM gate.acknowledgment_template WHERE template_id = 'TRAINING_RECEIPT'),
   now() - interval '195 days','SUPERVISOR_PROXY','D. Whitlock','Safety team',
   'Peoria IL - Plant 3081',NULL,'ACK-CR-40124-PROXY')
ON CONFLICT DO NOTHING;

UPDATE gate.acknowledgment SET proxy_for = 'Rafael Ibarra'
 WHERE document_ref = 'ACK-CR-40124-PROXY' AND proxy_for IS NULL;

-- Corporate policy attestations
INSERT INTO gate.acknowledgment
  (employee_id, policy_id, subject, kind, statement, signed_on, method, signed_by_name, location, document_ref)
SELECT a.employee_id, a.policy_id, p.title, 'POLICY_ATTESTATION',
       (SELECT statement FROM gate.acknowledgment_template WHERE template_id = 'POLICY_ATTESTATION'),
       a.completed_on + interval '11 hours', 'IN_APP', e.name, e.locationname,
       'ACK-' || a.policy_id || '-' || a.employee_id
  FROM gate.learning_assignment a
  JOIN gate.learning_policy p ON p.policy_id = a.policy_id
  JOIN gate.hr_employee e     ON e.id = a.employee_id
 WHERE a.completed_on IS NOT NULL AND p.category = 'COMPLIANCE'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW gate.v_acknowledgment AS
SELECT
    a.acknowledgment_id,
    a.employee_id,
    e.name         AS employee_name,
    e.descr        AS job_description,
    e.deptname     AS department,
    e.locationname AS location,
    e.supvid       AS supervisor_id,
    e.supvname     AS supervisor_name,
    e.workforce,
    a.subject,
    a.kind,
    a.statement,
    a.signed_on,
    a.signed_on::date AS signed_date,
    a.method,
    a.signed_by_name,
    a.proxy_for,
    a.trainer_name,
    a.document_ref,
    a.qualification_id,
    a.policy_id,
    (a.superseded_by IS NOT NULL) AS superseded,
    -- A proxy signature is a record that someone else signed on the worker's
    -- behalf. It is still evidence, but weaker, and an auditor treats it so.
    (a.method = 'SUPERVISOR_PROXY') AS is_proxy
FROM gate.acknowledgment a
JOIN gate.hr_employee e ON e.id = a.employee_id
WHERE a.superseded_by IS NULL;

-- Credentials held with no signed acknowledgment behind them.
--
-- The gap this table exists to find: the system believes the person is trained,
-- but there is nothing signed to show an inspector.
CREATE OR REPLACE VIEW gate.v_missing_acknowledgment AS
SELECT
    e.locationname AS location,
    e.id           AS employee_id,
    e.name         AS employee_name,
    e.descr        AS job_description,
    e.supvid       AS supervisor_id,
    e.supvname     AS supervisor_name,
    q.qualification_id,
    q.name         AS qualification_name,
    q.is_regulated,
    q.regulation_reference,
    eq.issued_on,
    eq.evidence_reference
FROM gate.employee_qualification eq
JOIN gate.qualification q ON q.qualification_id = eq.qualification_id
JOIN gate.hr_employee e   ON e.id = eq.employee_id
WHERE eq.revoked_on IS NULL
  AND (eq.expires_on IS NULL OR eq.expires_on > CURRENT_DATE)
  AND q.is_regulated
  AND NOT EXISTS (
      SELECT 1 FROM gate.acknowledgment a
       WHERE a.employee_id = eq.employee_id
         AND a.qualification_id = eq.qualification_id
         AND a.superseded_by IS NULL
  );
