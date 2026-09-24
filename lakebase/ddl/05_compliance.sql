-- OSHA high-hazard work authorization, and the daily site checklist
--
-- Applied before the audit file, which reads gate.v_hazwork_status from here.
--
-- Two additions that a general qualification model does not cover.
--
-- 1. OSHA high-hazard work authorization.
--
--    Some tasks on a plant floor are OSHA-regulated high-hazard work that a named
--    individual must be authorized to perform: the Lockout/Tagout authorized
--    employee who applies the energy-isolation lock (29 CFR 1910.147), the
--    Confined Space entrant and attendant (1910.146), the Process Safety
--    Management covered operator (1910.119). Not everyone does this work.
--
--    So the same site holds both populations. A general assembler is outside the
--    high-hazard authorization; a maintenance technician who locks out a press is
--    inside it. Recording "not applicable" explicitly matters as much as recording
--    an authorization, because an auditor asks why someone has none.
--
--    Reference: 29 CFR 1910.147 (Lockout/Tagout), 1910.146 (Confined Spaces),
--    1910.119 (Process Safety Management).
--
-- 2. The daily plant checklist.
--
--    Authorization answers whether the person is qualified. It says nothing about
--    whether the site was safe on the day. Both get asked for, so both belong
--    here, and a failed check links to a corrective action rather than sitting as
--    a note nobody owns.

-- ---------------------------------------------------------------------------
-- Lockout / tagout and hazard communication
-- ---------------------------------------------------------------------------
-- LOTO distinguishes authorized from affected: an authorized employee applies the
-- lock, an affected employee works on equipment that has been locked out. The
-- training duty differs, so a single boolean would lose the distinction an
-- auditor is checking.

ALTER TABLE gate.hr_employee
    ADD COLUMN IF NOT EXISTS loto_role text
        CHECK (loto_role IN ('AUTHORIZED', 'AFFECTED', 'NONE')),
    ADD COLUMN IF NOT EXISTS hazcom_trained_on date;

UPDATE gate.hr_employee SET loto_role = CASE
    WHEN descr ILIKE '%maintenance%' OR descr ILIKE '%technician%' THEN 'AUTHORIZED'
    WHEN descr ILIKE '%supervisor%'  OR descr ILIKE '%manager%'    THEN 'AUTHORIZED'
    WHEN descr ILIKE '%welder%'      OR descr ILIKE '%painter%'    THEN 'AFFECTED'
    WHEN descr ILIKE '%operator%'    OR descr ILIKE '%inspector%'  THEN 'AFFECTED'
    ELSE 'NONE' END
 WHERE loto_role IS NULL;

-- Hazard communication is an all-hands duty. One person deliberately has no
-- record, so the matrix has a HazCom gap to show.
UPDATE gate.hr_employee
   SET hazcom_trained_on = CURRENT_DATE - (150 + (abs(hashtext(id)) % 400)) * interval '1 day'
 WHERE hazcom_trained_on IS NULL AND id <> '40120';

-- ---------------------------------------------------------------------------
-- OSHA high-hazard work authorization
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS gate.hazwork_qualification (
    hazwork_qualification_id bigserial PRIMARY KEY,
    employee_id     text NOT NULL,
    -- The employer designates which OSHA high-hazard category applies
    occupational_category text,
    craft           text,
    -- False where the person's duties fall outside regulated high-hazard work,
    -- for example general assembly with no LOTO or confined-space obligation
    is_safety_related boolean NOT NULL DEFAULT true,
    not_applicable_reason text,
    qualified_on    date,
    expires_on      date,
    program_ref     text,
    -- OSHA also requires periodic re-evaluation (e.g. LOTO periodic inspection,
    -- powered-industrial-truck operator re-evaluation)
    last_oversight_on date,
    oversight_months  integer DEFAULT 12,
    UNIQUE (employee_id)
);

INSERT INTO gate.hazwork_qualification
  (employee_id, occupational_category, craft, is_safety_related, not_applicable_reason,
   qualified_on, expires_on, program_ref, last_oversight_on)
VALUES
  -- Inside regulated high-hazard work: LOTO, confined space, hot work
  ('40121','LOTO','LOTO Authorized — Maintenance',      true, NULL, CURRENT_DATE - interval '400 days', CURRENT_DATE + interval '330 days','OSHA-1910.147-LOTO', CURRENT_DATE - interval '200 days'),
  ('40124','LOTO','LOTO Authorized — Maintenance',      true, NULL, CURRENT_DATE - interval '600 days', CURRENT_DATE + interval '130 days','OSHA-1910.147-LOTO', CURRENT_DATE - interval '100 days'),
  -- Authorization current but periodic re-evaluation overdue: a finding in itself
  ('40118','HOT_WORK','Hot Work / Welding',             true, NULL, CURRENT_DATE - interval '500 days', CURRENT_DATE + interval '230 days','OSHA-HOTWORK-02', CURRENT_DATE - interval '500 days'),
  -- Lapsed
  ('40119','CONFINED_SPACE','Confined Space Entrant',   true, NULL, CURRENT_DATE - interval '800 days', CURRENT_DATE - interval '40 days', 'OSHA-1910.146-CS', CURRENT_DATE - interval '300 days'),
  -- Outside regulated high-hazard work: general assembly, no LOTO/CS obligation
  ('40120','General', NULL, false, 'General assembly only; no LOTO or confined-space duties',        NULL, NULL, NULL, NULL),
  ('40122','General', NULL, false, 'Materials handling within the plant; not a LOTO-authorized role', NULL, NULL, NULL, NULL),
  ('40123','General', NULL, false, 'Coating on finished goods; no confined-space or LOTO obligation', NULL, NULL, NULL, NULL),
  ('40125','General', NULL, false, 'Quality inspection only; no regulated high-hazard duties',        NULL, NULL, NULL, NULL),
  ('40210','LOTO','LOTO Authorized — Maintenance',      true, NULL, CURRENT_DATE - interval '350 days', CURRENT_DATE + interval '380 days','OSHA-1910.147-LOTO', CURRENT_DATE - interval '150 days'),
  ('40211','General', NULL, false, 'Materials handling within the plant',                             NULL, NULL, NULL, NULL)
ON CONFLICT (employee_id) DO NOTHING;

CREATE OR REPLACE VIEW gate.v_hazwork_status AS
SELECT
    f.employee_id,
    e.name         AS employee_name,
    e.locationname AS location,
    e.descr        AS job_description,
    f.occupational_category,
    f.craft,
    f.is_safety_related,
    f.not_applicable_reason,
    f.qualified_on,
    f.expires_on,
    f.program_ref,
    f.last_oversight_on,
    f.oversight_months,
    CASE
        WHEN NOT f.is_safety_related                              THEN 'NOT_APPLICABLE'
        WHEN f.qualified_on IS NULL                               THEN 'NOT_QUALIFIED'
        WHEN f.expires_on IS NOT NULL AND f.expires_on < CURRENT_DATE THEN 'EXPIRED'
        WHEN f.last_oversight_on IS NULL
          OR f.last_oversight_on < CURRENT_DATE - (f.oversight_months || ' months')::interval
                                                                  THEN 'OVERSIGHT_OVERDUE'
        WHEN f.expires_on IS NOT NULL
         AND f.expires_on <= CURRENT_DATE + interval '60 days'     THEN 'EXPIRING'
        ELSE 'QUALIFIED'
    END AS hazwork_status
FROM gate.hazwork_qualification f
JOIN gate.hr_employee e ON e.id = f.employee_id;

-- ---------------------------------------------------------------------------
-- Daily plant checklist
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS gate.checklist_item (
    checklist_item_id text PRIMARY KEY,
    area         text NOT NULL,
    standard_ref text,
    -- Some items do not apply at every site
    applies_to   text NOT NULL DEFAULT 'ALL' CHECK (applies_to IN ('ALL', 'HIGH_HAZARD', 'SHOP')),
    sort_order   integer NOT NULL DEFAULT 100
);

INSERT INTO gate.checklist_item (checklist_item_id, area, standard_ref, applies_to, sort_order)
VALUES
  ('LOTO_LOCKS',    'Lockout/tagout locks and tags staged','OSHA 1910.147',        'HIGH_HAZARD', 10),
  ('CS_PERMIT',     'Confined space permits current',      'OSHA 1910.146',        'HIGH_HAZARD', 20),
  ('HOTWORK_PERMIT','Hot work permits and fire watch',     'OSHA 1910.252',        'HIGH_HAZARD', 30),
  ('PIT_INSPECT',   'Powered industrial truck inspection', 'OSHA 1910.178',        'SHOP',        40),
  ('GUARDING',      'Machine guarding',                    'OSHA 1910.212',        'SHOP',        50),
  ('EYEWASH',       'Emergency eyewash stations',          'OSHA 1910.151(c)',     'ALL',         60),
  ('EGRESS',        'Exit routes and egress',              'OSHA 1910.37',         'ALL',         70),
  ('PPE_STATION',   'PPE stations stocked',                'OSHA 1910.132',        'ALL',         80)
ON CONFLICT (checklist_item_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS gate.checklist_result (
    checklist_result_id bigserial PRIMARY KEY,
    checklist_item_id text NOT NULL REFERENCES gate.checklist_item (checklist_item_id),
    site_id      text NOT NULL REFERENCES gate.site (site_id),
    checked_on   date NOT NULL,
    checked_by   text,
    status       text NOT NULL CHECK (status IN ('PASS', 'FAIL', 'NOT_APPLICABLE')),
    field_note   text,
    -- Links a failed check to the corrective action that owns it, so a gap
    -- cannot be closed by being forgotten
    corrective_action_id text,
    UNIQUE (checklist_item_id, site_id, checked_on)
);

CREATE TABLE IF NOT EXISTS gate.corrective_action (
    corrective_action_id text PRIMARY KEY,
    raised_on   date NOT NULL,
    site_id     text REFERENCES gate.site (site_id),
    description text NOT NULL,
    owner_name  text,
    due_on      date,
    status      text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'IN_PROGRESS', 'CLOSED')),
    closed_on   date
);

INSERT INTO gate.corrective_action (corrective_action_id, raised_on, site_id, description, owner_name, due_on, status)
VALUES
  ('CAP-004', CURRENT_DATE - 1, 'PEIL','Scrapped steel plates blocking the walkway near the loading dock','C. Lindahl', CURRENT_DATE + 2,'IN_PROGRESS'),
  ('CAP-005', CURRENT_DATE - 4, 'PEIL','Eyewash station in the paint bay flow rate below standard','G. Pruitt',  CURRENT_DATE - 1,'OPEN')
ON CONFLICT (corrective_action_id) DO NOTHING;

INSERT INTO gate.checklist_result (checklist_item_id, site_id, checked_on, checked_by, status, field_note, corrective_action_id)
VALUES
  ('LOTO_LOCKS',    'PEIL', CURRENT_DATE - 1,'R. Vance','PASS','Lockout locks and tags staged at each press during maintenance',  NULL),
  ('CS_PERMIT',     'PEIL', CURRENT_DATE - 1,'R. Vance','PASS','Confined space entry permit posted and attendant assigned',        NULL),
  ('HOTWORK_PERMIT','PEIL', CURRENT_DATE - 1,'R. Vance','PASS','Hot work permit issued, fire watch in place at the weld bay',       NULL),
  ('GUARDING',      'PEIL', CURRENT_DATE - 1,'C. Lindahl','PASS','Wheel grinders and shop presses guarded, guards intact',          NULL),
  ('EYEWASH',       'PEIL', CURRENT_DATE - 1,'C. Lindahl','FAIL','Paint bay station flow rate below standard','CAP-005'),
  ('EGRESS',        'PEIL', CURRENT_DATE - 1,'C. Lindahl','FAIL','Scrapped steel plates blocking the walkway near the loading dock','CAP-004'),
  ('PIT_INSPECT',   'PEIL', CURRENT_DATE - 1,'C. Lindahl','PASS','Daily forklift inspection logged at both docks',                  NULL),
  ('PPE_STATION',   'PEIL', CURRENT_DATE - 1,'C. Lindahl','PASS','Stocked at both entries',                                         NULL)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE VIEW gate.v_site_checklist AS
SELECT
    s.locationname AS location,
    s.label        AS site_label,
    i.checklist_item_id,
    i.area,
    i.standard_ref,
    i.applies_to,
    i.sort_order,
    r.checked_on,
    r.checked_by,
    COALESCE(r.status, 'NOT_CHECKED') AS status,
    r.field_note,
    r.corrective_action_id,
    ca.description AS corrective_description,
    ca.owner_name  AS corrective_owner,
    ca.due_on      AS corrective_due_on,
    ca.status      AS corrective_status
FROM gate.site s
CROSS JOIN gate.checklist_item i
LEFT JOIN gate.checklist_result r
       ON r.checklist_item_id = i.checklist_item_id
      AND r.site_id = s.site_id
      AND r.checked_on = (SELECT max(checked_on) FROM gate.checklist_result r2
                           WHERE r2.site_id = s.site_id)
LEFT JOIN gate.corrective_action ca ON ca.corrective_action_id = r.corrective_action_id
WHERE s.locationname IS NOT NULL
ORDER BY s.label, i.sort_order;
