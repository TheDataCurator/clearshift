-- Trend
--
-- Everything else in this model answers "where are we". This answers "are we
-- getting better", which is a different question and the one asked first.
--
-- **The history is already in the source tables.** Requirements are effective-dated,
-- credentials carry issued, expires and revoked, and the schedule is keyed on
-- work_date. So "was this person cleared on the fifteenth" is answerable today,
-- without having accumulated anything. v_trend_derived below computes it.
--
-- Two things do need to be captured going forward, because nothing records them:
--
--   1. Whether a supervised first performance actually had a supervisor present.
--      gate.first_performance holds the sign-off, so this is captured from the day
--      the control is switched on, but not before.
--   2. When a finding was closed. Findings are computed from current state, so a
--      gap that was fixed leaves no trace of having existed. Time-to-close cannot
--      be reconstructed retrospectively.
--
-- The snapshot table is therefore worth keeping for the second kind, and the demo
-- history below stands in for a program that has been running a quarter.
--
-- Three properties this view has to get right, or the chart misleads:
--
--   1. Coverage falls when a site onboards, because a plant's worth of unassessed
--      people joins the denominator. That is the program working. Same-site
--      coverage is therefore reported separately from network coverage, or good
--      news reads as bad.
--
--   2. Some counts should rise. A supervised first performance that was caught is
--      a success. The number that should fall is first performances that happened
--      unsupervised. Putting both on one axis pointing one way would be wrong.
--
--   3. Falling exposure has an innocent and a sinister reading: the gate is
--      working, or the schedule feed stopped. Scheduled-shift volume is carried
--      alongside so the two can be told apart.

CREATE TABLE IF NOT EXISTS gate.daily_snapshot (
    snapshot_on            date NOT NULL,
    location               text NOT NULL,
    -- Exposure
    scheduled_shifts       integer NOT NULL DEFAULT 0,
    blocked                integer NOT NULL DEFAULT 0,
    supervision_required   integer NOT NULL DEFAULT 0,
    -- Of those, the ones that went ahead without a supervisor present. This is
    -- the number that should fall.
    unsupervised_first_performance integer NOT NULL DEFAULT 0,
    -- Coverage
    people_assessed        integer NOT NULL DEFAULT 0,
    people_covered         integer NOT NULL DEFAULT 0,
    -- Findings and their age
    findings_open          integer NOT NULL DEFAULT 0,
    findings_closed_today  integer NOT NULL DEFAULT 0,
    median_days_to_close   numeric(6,1),
    -- Renewals
    lapsed                 integer NOT NULL DEFAULT 0,
    renewed_on_time        integer NOT NULL DEFAULT 0,
    -- Whether the site was live on this date, so same-site series can exclude
    -- days before onboarding rather than reporting them as zero
    is_onboarded           boolean NOT NULL DEFAULT false,
    PRIMARY KEY (snapshot_on, location)
);

-- ---------------------------------------------------------------------------
-- Demo history
-- ---------------------------------------------------------------------------
-- Sixteen weeks of daily rows. Shaped to tell the truth about a rollout rather
-- than to look good: exposure falls at a site once it is onboarded, network
-- coverage dips when the second site joins, and unsupervised first performances
-- fall to zero while supervised ones continue.
--
-- Generated once and left alone. Regenerating on every run would make the trend
-- move under the reader's feet.

INSERT INTO gate.daily_snapshot
    (snapshot_on, location, scheduled_shifts, blocked, supervision_required,
     unsupervised_first_performance, people_assessed, people_covered,
     findings_open, findings_closed_today, median_days_to_close,
     lapsed, renewed_on_time, is_onboarded)
SELECT
    d::date,
    s.locationname,
    -- Weekday volume only; a weekend of zeros would read as a feed outage
    CASE WHEN EXTRACT(dow FROM d) IN (0, 6) THEN 0 ELSE base.shifts END,
    -- Exposure decays after onboarding, with day-to-day noise
    CASE WHEN d::date < s.onboarded_on OR EXTRACT(dow FROM d) IN (0, 6) THEN 0
         ELSE greatest(0, round(base.blocked0
              * exp(-0.030 * (d::date - s.onboarded_on))
              + 1.4 * sin((d::date - s.onboarded_on) / 2.1))::int) END,
    CASE WHEN d::date < s.onboarded_on OR EXTRACT(dow FROM d) IN (0, 6) THEN 0
         ELSE greatest(0, round(1.8 + 1.2 * sin((d::date - s.onboarded_on) / 3.7))::int) END,
    -- Unsupervised first performances: the control taking hold
    CASE WHEN d::date < s.onboarded_on OR EXTRACT(dow FROM d) IN (0, 6) THEN 0
         ELSE greatest(0, round(base.unsup0
              * exp(-0.075 * (d::date - s.onboarded_on)))::int) END,
    -- Assessed population appears at onboarding and holds
    CASE WHEN d::date < s.onboarded_on THEN 0 ELSE base.assessed END,
    CASE WHEN d::date < s.onboarded_on THEN 0
         ELSE least(base.assessed,
              round(base.assessed * (0.55 + 0.42 * (1 - exp(-0.045 * (d::date - s.onboarded_on)))))::int) END,
    CASE WHEN d::date < s.onboarded_on THEN 0
         ELSE greatest(0, round(base.findings0
              * exp(-0.022 * (d::date - s.onboarded_on)) + 1.1 * sin((d::date - s.onboarded_on) / 4.3))::int) END,
    CASE WHEN d::date < s.onboarded_on OR EXTRACT(dow FROM d) IN (0, 6) THEN 0
         ELSE (abs(hashtext(s.site_id || d::text)) % 3) END,
    CASE WHEN d::date < s.onboarded_on THEN NULL
         ELSE round((22.0 - 11.0 * (1 - exp(-0.030 * (d::date - s.onboarded_on))))::numeric, 1) END,
    CASE WHEN d::date < s.onboarded_on THEN 0
         ELSE greatest(0, round(base.lapsed0
              * exp(-0.028 * (d::date - s.onboarded_on)))::int) END,
    CASE WHEN d::date < s.onboarded_on OR EXTRACT(dow FROM d) IN (0, 6) THEN 0
         ELSE (abs(hashtext(s.locationname || d::text)) % 4) END,
    d::date >= s.onboarded_on
FROM generate_series(CURRENT_DATE - interval '112 days', CURRENT_DATE, interval '1 day') AS d
CROSS JOIN (
    -- The two sites with real rosters. Peoria leads; Grand Rapids joins later,
    -- which is what makes network coverage dip while site coverage climbs.
    SELECT 'PEIL' AS site_id, 'Peoria IL - Plant 3081' AS locationname,
           (CURRENT_DATE - interval '98 days')::date AS onboarded_on
    UNION ALL
    SELECT 'GRMI', 'Grand Rapids MI - Plant 2401',
           (CURRENT_DATE - interval '42 days')::date
) s
CROSS JOIN LATERAL (
    SELECT
        CASE s.site_id WHEN 'PEIL' THEN 34 ELSE 21 END  AS shifts,
        CASE s.site_id WHEN 'PEIL' THEN 11 ELSE 7  END  AS blocked0,
        CASE s.site_id WHEN 'PEIL' THEN 4  ELSE 3  END  AS unsup0,
        CASE s.site_id WHEN 'PEIL' THEN 8  ELSE 5  END  AS assessed,
        CASE s.site_id WHEN 'PEIL' THEN 19 ELSE 12 END  AS findings0,
        CASE s.site_id WHEN 'PEIL' THEN 6  ELSE 4  END  AS lapsed0
) base
ON CONFLICT (snapshot_on, location) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Weekly series
-- ---------------------------------------------------------------------------
-- Weekly rather than daily: a daily line on this data is mostly noise, and the
-- question is direction over a quarter.

CREATE OR REPLACE VIEW gate.v_trend_weekly AS
WITH wk AS (
    SELECT
        date_trunc('week', snapshot_on)::date AS week_of,
        location,
        sum(scheduled_shifts)                        AS scheduled_shifts,
        sum(blocked)                                 AS blocked,
        sum(supervision_required)                    AS supervision_required,
        sum(unsupervised_first_performance)          AS unsupervised_first_performance,
        sum(findings_closed_today)                   AS findings_closed,
        sum(renewed_on_time)                         AS renewed_on_time,
        -- Point-in-time measures take the last day of the week, not a sum
        (array_agg(people_assessed  ORDER BY snapshot_on DESC))[1] AS people_assessed,
        (array_agg(people_covered   ORDER BY snapshot_on DESC))[1] AS people_covered,
        (array_agg(findings_open    ORDER BY snapshot_on DESC))[1] AS findings_open,
        (array_agg(lapsed           ORDER BY snapshot_on DESC))[1] AS lapsed,
        (array_agg(median_days_to_close ORDER BY snapshot_on DESC))[1] AS median_days_to_close,
        bool_or(is_onboarded)                        AS was_onboarded
    FROM gate.daily_snapshot
    GROUP BY 1, 2
)
SELECT
    week_of,
    location,
    scheduled_shifts,
    blocked,
    supervision_required,
    unsupervised_first_performance,
    people_assessed,
    people_covered,
    findings_open,
    findings_closed,
    median_days_to_close,
    lapsed,
    renewed_on_time,
    was_onboarded,
    CASE WHEN people_assessed > 0
         THEN round(100.0 * people_covered / people_assessed, 0) END AS coverage_pct,
    -- Exposure per hundred scheduled shifts, so a quieter week does not read as
    -- an improvement
    CASE WHEN scheduled_shifts > 0
         THEN round(100.0 * blocked / scheduled_shifts, 1) END AS blocked_per_100_shifts
FROM wk
ORDER BY week_of, location;

-- Network roll-up, with the two coverage readings kept apart.
CREATE OR REPLACE VIEW gate.v_trend_network AS
WITH wk AS (
    SELECT
        week_of,
        sum(scheduled_shifts)               AS scheduled_shifts,
        sum(blocked)                        AS blocked,
        sum(supervision_required)           AS supervision_required,
        sum(unsupervised_first_performance) AS unsupervised_first_performance,
        sum(findings_open)                  AS findings_open,
        sum(findings_closed)                AS findings_closed,
        sum(lapsed)                         AS lapsed,
        sum(renewed_on_time)                AS renewed_on_time,
        sum(people_assessed)                AS people_assessed,
        sum(people_covered)                 AS people_covered,
        round(avg(median_days_to_close) FILTER (WHERE median_days_to_close IS NOT NULL), 1)
                                            AS median_days_to_close,
        count(*) FILTER (WHERE was_onboarded) AS sites_onboarded,
        -- Same-site coverage: only sites that were already live at the start of
        -- the window, so onboarding a new plant does not depress the line
        sum(people_covered)  FILTER (WHERE location = 'Peoria IL - Plant 3081') AS baseline_covered,
        sum(people_assessed) FILTER (WHERE location = 'Peoria IL - Plant 3081') AS baseline_assessed
    FROM gate.v_trend_weekly
    GROUP BY week_of
)
SELECT
    week_of,
    scheduled_shifts,
    blocked,
    supervision_required,
    unsupervised_first_performance,
    findings_open,
    findings_closed,
    lapsed,
    renewed_on_time,
    people_assessed,
    people_covered,
    median_days_to_close,
    sites_onboarded,
    CASE WHEN people_assessed > 0
         THEN round(100.0 * people_covered / people_assessed, 0) END AS coverage_pct,
    CASE WHEN baseline_assessed > 0
         THEN round(100.0 * baseline_covered / baseline_assessed, 0) END AS baseline_coverage_pct,
    CASE WHEN scheduled_shifts > 0
         THEN round(100.0 * blocked / scheduled_shifts, 1) END AS blocked_per_100_shifts
FROM wk
-- Weeks before the first site onboarded report zero exposure because nothing was
-- assessed yet, not because nothing was wrong. Including them makes the first
-- real week look like a regression.
WHERE scheduled_shifts > 0
  AND sites_onboarded > 0
ORDER BY week_of;

-- ---------------------------------------------------------------------------
-- Derived history
-- ---------------------------------------------------------------------------
-- Recomputes the gate for every date the schedule covers, using only columns the
-- source tables already carry. This is the part a customer does not need to start
-- capturing: it is already there, and running this proves it.
--
-- What it cannot recover is in the header above. Anything requiring knowledge of
-- what someone did about a gap has to be recorded as it happens.

CREATE OR REPLACE VIEW gate.v_trend_derived AS
WITH shift_req AS (
    -- Every requirement that applied on every scheduled date
    SELECT DISTINCT
        h.work_date,
        e.locationname AS location,
        h.employee_id,
        wr.qualification_id
    FROM gate.employee_scheduled_workcenter_history h
    JOIN gate.hr_employee e ON e.id = h.employee_id
    JOIN gate.workcenter_requirement wr
      ON wr.work_center_id = h.scheduled_wc_code
     AND wr.effective_from <= h.work_date
     AND (wr.effective_to IS NULL OR wr.effective_to > h.work_date)
),
resolved AS (
    SELECT
        r.*,
        EXISTS (
            SELECT 1 FROM gate.employee_qualification eq
             WHERE eq.employee_id      = r.employee_id
               AND eq.qualification_id = r.qualification_id
               AND eq.issued_on       <= r.work_date
               AND (eq.expires_on IS NULL OR eq.expires_on > r.work_date)
               AND (eq.revoked_on IS NULL OR eq.revoked_on > r.work_date)
        ) AS held_on_the_day
    FROM shift_req r
)
SELECT
    work_date,
    location,
    count(DISTINCT employee_id)                                       AS people_scheduled,
    count(*)                                                          AS requirements,
    count(*) FILTER (WHERE held_on_the_day)                           AS requirements_met,
    count(DISTINCT employee_id) FILTER (WHERE NOT held_on_the_day)    AS people_blocked,
    CASE WHEN count(*) > 0
         THEN round(100.0 * count(*) FILTER (WHERE held_on_the_day) / count(*), 1) END
                                                                      AS met_pct
FROM resolved
GROUP BY work_date, location
ORDER BY work_date, location;
