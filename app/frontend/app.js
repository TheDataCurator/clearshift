/* Qualification Gate — client
 *
 * Verdicts are carried by an icon and a word as well as a color, so nothing
 * depends on hue alone.
 */

const LOOK = {
  NOT_CLEARED:          { cls: 'stop',    ico: '✕', word: 'Not cleared' },
  SUPERVISION_REQUIRED: { cls: 'caution', ico: '◆', word: 'Supervision required' },
  CLEARED_EXPIRING:     { cls: 'watch',   ico: '▲', word: 'Cleared, expiring' },
  CLEARED:              { cls: 'go',      ico: '✓', word: 'Cleared' },
};

const STATE = {
  MISSING:      { cls: 'stop',    ico: '✕' },
  EXPIRED:      { cls: 'stop',    ico: '✕' },
  REVOKED:      { cls: 'stop',    ico: '✕' },
  OUT_OF_SCOPE: { cls: 'stop',    ico: '✕' },
  EXPIRING:     { cls: 'watch',   ico: '▲' },
  CURRENT:      { cls: 'go',      ico: '✓' },
};

const BUCKET = {
  LAPSED: { cls: 'stop',    ico: '✕', word: 'Lapsed' },
  DUE_30: { cls: 'caution', ico: '◆', word: 'Due in 30 days' },
  DUE_60: { cls: 'watch',   ico: '▲', word: 'Due in 60 days' },
  DUE_90: { cls: 'go',      ico: '○', word: 'Due in 90 days' },
};

let principal = null;

// Reporting-line scopes read as bare numbers otherwise, which tells a viewer
// nothing about whose team they are looking at.
const SUPERVISOR_NAME = {
  '40101': 'Rosalind Vance (Welding)',
  '40102': 'Curtis Lindahl (Maintenance)',
  '40103': 'Gerald Pruitt (Paint/Blast)',
};

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const fmtDate = (iso) => {
  if (!iso) return '—';
  const d = new Date(iso + (iso.length === 10 ? 'T00:00:00' : ''));
  return d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });
};

async function api(path, opts) {
  const res = await fetch(path, opts);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

function toast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.remove('hidden');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.add('hidden'), 3200);
}


/* Every table in this application has the same shape: a header row and a body
 * built from an array. Seven copies of that boilerplate is seven places to make
 * the same mistake, so it lives here once.
 *
 * `cols` is an array of header labels. `row` returns the inner HTML of one <tr>.
 */

/* Sub-tabs within a section.
 *
 * A section holding seven stacked panels reads as one long document rather than a
 * view. Grouping them behind sub-tabs keeps each screen to one idea and the scroll
 * short enough that the section boundary is obvious.
 */
function wireSubtabs(navId, panePrefix, onChange) {
  const tabs = document.querySelectorAll(`#${navId} .subtab`);
  if (!tabs.length || tabs[0].dataset.wired) return;
  tabs.forEach((t) => {
    t.dataset.wired = '1';
    t.addEventListener('click', () => {
      tabs.forEach((x) => {
        const on = x === t;
        x.classList.toggle('active', on);
        x.setAttribute('aria-selected', on ? 'true' : 'false');
        const pane = document.getElementById(`${panePrefix}-${x.dataset.mode}`);
        if (pane) pane.classList.toggle('hidden', !on);
      });
      window.scrollTo({ top: 0, behavior: 'instant' });
      if (onChange) onChange(t.dataset.mode);
    });
  });
}

function renderTable(el, cols, rows, row, emptyMsg) {
  if (!rows.length) {
    el.innerHTML = `<tr><td class="empty" colspan="${cols.length}">${esc(emptyMsg || 'Nothing to show.')}</td></tr>`;
    return;
  }
  el.innerHTML = '<thead><tr>' + cols.map((c) => `<th>${esc(c)}</th>`).join('') + '</tr></thead>'
    + '<tbody>' + rows.map((r) => `<tr>${row(r)}</tr>`).join('') + '</tbody>';
}

/* A status pill. Fifteen inline copies drifted apart; this keeps icon, word and
 * class together so a status can only render one way. */
function pill(look, label) {
  if (!look) return '<span class="mono">—</span>';
  const text = label !== undefined ? label : (look.word || '');
  return `<span class="pill ${look.cls}">${look.ico ? look.ico + ' ' : ''}${esc(text)}</span>`;
}

const cell = (v) => `<td>${esc(v ?? '—')}</td>`;
const mono = (v) => `<td class="mono">${esc(v ?? '—')}</td>`;

function tile(cls, n, k) {
  return `<div class="tile ${cls}"><div class="n">${n}</div><div class="k">${esc(k)}</div></div>`;
}


/* ---------------------------------------------------------------------------
 * Actions
 *
 * Identifying a gap is not closing one. These are the two things a reader can do
 * from what they are looking at: ask a supervisor to consider someone for a
 * credential, and take the evidence away as a file.
 *
 * Both are recorded rather than sent. The request is the artifact and it is
 * auditable; whether it leaves as mail, a chat message or a ticket is a delivery
 * detail that belongs to whatever the customer already runs.
 * ------------------------------------------------------------------------- */

// A file the reader can attach to a mail, open in a spreadsheet, or hand over.
function toCsv(rows, cols) {
  const esc = (v) => {
    const s = v === null || v === undefined ? '' : String(v);
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  return [cols.map((c) => esc(c.label)).join(',')]
    .concat(rows.map((r) => cols.map((c) => esc(c.get(r))).join(',')))
    .join('\n');
}

function download(name, text, mime = 'text/csv') {
  const blob = new Blob([text], { type: `${mime};charset=utf-8` });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

const stamp = () => new Date().toISOString().slice(0, 10);

// Ask a supervisor to consider someone. The wording is a draft the requester
// edits, not a message sent on their behalf without sight of it.
function requestBody(c, gap) {
  return [
    `${c.employee_name} (${c.job_description}, ${c.department}) is a candidate for `
      + `${gap.qualification_name} at ${gap.location}.`,
    '',
    gap.qualified_now === 0
      ? `Nobody at this site currently holds it.`
      : `${gap.qualified_now} person currently holds it, so the site has no cover if they are absent.`,
    c.route === 'RENEW'
      ? 'They held it previously, so this is a renewal rather than new training.'
      : c.previously_revoked
        ? `Note: previously revoked — ${c.revoked_reason || 'reason not recorded'}. `
          + 'Requalification is a judgment for you to make.'
        : `They hold ${c.credentials_held} other regulated credentials`
          + (c.already_assigned_to_such_work
              ? ' and are already assigned to work requiring this one.' : '.'),
  ].join('\n');
}

async function sendCredentialingRequest(btn) {
  const c = JSON.parse(btn.dataset.cand);
  const g = JSON.parse(btn.dataset.gap);
  btn.disabled = true;
  try {
    await api('/api/gate/credentialing-request', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        employee_id: c.employee_id,
        qualification_id: g.qualification_id,
        location: g.location,
        supervisor_name: c.supervisor_name,
        requested_by: principal,
        qualified_now: g.qualified_now,
        cover_state: g.cover_state,
        route: c.route,
        note: requestBody(c, g),
      }),
    });
    btn.textContent = '✓ Requested';
    const note = btn.parentElement.querySelector('.cand-note');
    if (note) note.textContent = `Sent to ${c.supervisor_name || 'their supervisor'}`;
    toast(`Credentialing request recorded for ${c.employee_name}.`);
  } catch (e) {
    btn.disabled = false;
    toast(`Could not record the request: ${e.message}`);
  }
}


// The matrix as a spreadsheet: it is a roster, and an inspector or coordinator
// sorts and filters it.
function exportMatrix(rows) {
  const cols = [
    { label: 'Worker',             get: (r) => r.employee_name },
    { label: 'Job title',          get: (r) => r.job_description },
    { label: 'Department',         get: (r) => r.department },
    { label: 'Location',           get: (r) => r.location },
    { label: 'Supervisor',         get: (r) => r.supervisor_name },
    { label: 'Supervisory role',   get: (r) => (r.is_supervisory ? 'yes' : 'no') },
    { label: 'OSHA 10 date',       get: (r) => r.osha10_on },
    { label: 'OSHA 10 card',       get: (r) => r.osha10_serial },
    { label: 'OSHA 30 date',       get: (r) => r.osha30_on },
    { label: 'OSHA 30 card',       get: (r) => r.osha30_serial },
    { label: 'Trainer',            get: (r) => r.osha30_trainer || r.osha10_trainer },
    { label: 'LOTO role',          get: (r) => r.loto_role },
    { label: 'HazCom trained',     get: (r) => (r.hazcom_trained ? 'yes' : 'no') },
    { label: 'Credentials held',   get: (r) => r.credentials_held },
    { label: 'Credentials required', get: (r) => r.credentials_required },
    { label: 'Not held',           get: (r) => r.missing_list },
    { label: 'Practical overdue',  get: (r) => r.practical_overdue_list },
    { label: 'OSHA high-hazard',   get: (r) => (r.hazwork_regulated ? r.hazwork_status : 'not applicable') },
    { label: 'Hazard authorization', get: (r) => r.hazwork_craft || r.hazwork_na_reason },
    { label: 'Competent person for', get: (r) => r.competent_for },
    { label: 'Status',             get: (r) => r.audit_status },
  ];
  download(`training-certification-matrix-${stamp()}.csv`, toCsv(rows, cols));
  toast(`Exported ${rows.length} rows.`);
}

function exportRenewals(rows) {
  const cols = [
    { label: 'Worker',        get: (r) => r.employee_name },
    { label: 'Location',      get: (r) => r.location },
    { label: 'Department',    get: (r) => r.department },
    { label: 'Supervisor',    get: (r) => r.supervisor_name },
    { label: 'Qualification', get: (r) => r.qualification_name },
    { label: 'Expires',       get: (r) => r.expires_on },
    { label: 'Days',          get: (r) => r.days_until_expiry },
    { label: 'Bucket',        get: (r) => r.bucket },
  ];
  download(`renewals-${stamp()}.csv`, toCsv(rows, cols));
  toast(`Exported ${rows.length} rows.`);
}

// Renewals are notified in a batch, because a coordinator works a list rather
// than one row at a time. One request per row keeps the record per credential.
async function notifyRenewals(rows) {
  let ok = 0;
  for (const r of rows) {
    try {
      await api('/api/gate/credentialing-request', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          employee_id: r.employee_id,
          qualification_id: r.qualification_id,
          location: r.location,
          supervisor_name: r.supervisor_name,
          requested_by: principal,
          route: 'RENEW',
          note: `${r.qualification_name} for ${r.employee_name} `
            + (r.days_until_expiry < 0
                ? `lapsed ${Math.abs(r.days_until_expiry)} days ago.`
                : `expires in ${r.days_until_expiry} days (${r.expires_on}).`)
            + ' Renewal rather than new training.',
        }),
      });
      ok += 1;
    } catch { /* keep going; the count reports what landed */ }
  }
  toast(ok === rows.length
    ? `${ok} reminder${ok === 1 ? '' : 's'} recorded.`
    : `${ok} of ${rows.length} recorded.`);
}

// ---------------------------------------------------------------- shift view

async function loadShift() {
  const data = await api(`/api/gate/shift-clearance?principal=${encodeURIComponent(principal)}`);
  document.getElementById('shift-date').textContent = fmtDate(data.work_date);

  const s = data.summary;
  document.getElementById('shift-tiles').innerHTML =
      tile('stop',    s.not_cleared,          s.not_cleared === 1 ? 'Not cleared' : 'Not cleared')
    + tile('caution', s.supervision_required, 'Supervision required')
    + tile('watch',   s.expiring,             'Expiring soon')
    + tile('go',      s.cleared,              'Cleared');

  const list = document.getElementById('shift-list');
  if (!data.employees.length) {
    list.innerHTML = `<div class="tablewrap"><p class="empty">No scheduled work for this date within your scope.</p></div>`;
    return;
  }

  list.innerHTML = data.employees.map((e) => {
    const look = LOOK[e.clearance];

    const reqs = e.requirements.map((r) => {
      const st = STATE[r.state] || STATE.MISSING;
      const cls = r.clearance === 'SUPERVISION_REQUIRED' ? 'caution' : st.cls;
      const ico = r.clearance === 'SUPERVISION_REQUIRED' ? '◆' : st.ico;
      const reg = r.regulation_reference ? `<span class="reg">${esc(r.regulation_reference)}</span>` : '';
      const ev  = r.evidence_reference   ? `<span class="ev">${esc(r.evidence_reference)}</span>` : '';
      return `<div class="req ${cls}">
                <span class="dot">${ico}</span>
                <span style="flex:1;min-width:0">
                  <span class="qn">${esc(r.qualification_name)}</span>${reg}<br>
                  <span class="rs">${esc(r.reason)}</span>
                </span>
                ${ev}
              </div>`;
    }).join('');

    // Sign-off appears only where a supervised first performance is outstanding
    const pending = e.requirements.find((r) => r.clearance === 'SUPERVISION_REQUIRED');
    const actions = pending ? `
      <div class="actions">
        <button class="signoff"
                data-employee="${esc(e.employee_id)}"
                data-qual="${esc(pending.qualification_id)}"
                data-wc="${esc(e.work_center_id || '')}"
                data-date="${esc(e.work_date)}"
                data-sup="${esc(e.supervisor_name || '')}">
          Record supervised performance
        </button>
        <p class="hint">Signing off names you as the supervisor present. The record is retained as audit evidence.</p>
      </div>` : '';

    const first = e.first_time_at_work_center
      ? ' <span class="mono">· first time at this work center</span>' : '';

    return `<article class="card ${look.cls}">
      <div class="card-main">
        <div class="who">
          <div class="name">${esc(e.employee_name)}</div>
          <div class="meta">${esc(e.job_description)} · ${esc(e.department)} · ${esc(e.location)}</div>
          <div class="where">Scheduled: <b>${esc(e.work_center_desc)}</b>${first}</div>
          <div class="meta">Supervisor: ${esc(e.supervisor_name || '—')}</div>
        </div>
        <span class="verdict ${look.cls}"><span class="ico">${look.ico}</span>${look.word}</span>
      </div>
      <div class="reqs">${reqs}</div>
      ${actions}
    </article>`;
  }).join('');

  list.querySelectorAll('button.signoff').forEach((btn) => {
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      try {
        await api('/api/gate/first-performance/sign-off', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            employee_id: btn.dataset.employee,
            qualification_id: btn.dataset.qual,
            work_center_id: btn.dataset.wc,
            work_date: btn.dataset.date,
            supervised_by: btn.dataset.sup || principal,
          }),
        });
        toast('Supervised performance recorded.');
        loadShift();
      } catch (err) {
        toast(`Could not record: ${err.message}`);
        btn.disabled = false;
      }
    });
  });
}

// ----------------------------------------------------------------- site view

async function loadSite() {
  const data = await api(`/api/gate/site-roster?principal=${encodeURIComponent(principal)}`);
  document.getElementById('roster-date').textContent = fmtDate(data.as_of);

  const s = data.summary;
  document.getElementById('site-tiles').innerHTML =
      tile('go',   s.compliant,        'Fully qualified')
    + tile('stop', s.people_with_gaps, 'With a gap')
    + tile('',     s.people,           'Active workers in scope');

  const t = document.getElementById('site-table');
  if (!data.rows.length) {
    t.outerHTML = `<table id="site-table"><tr><td class="empty">Nothing in scope.</td></tr></table>`;
    return;
  }

  const rank = { MISSING: 1, EXPIRED: 2, REVOKED: 3, OUT_OF_SCOPE: 4, EXPIRING: 5, CURRENT: 6 };
  const rows = [...data.rows].sort((a, b) =>
    (rank[a.qualification_state] || 9) - (rank[b.qualification_state] || 9)
    || a.employee_name.localeCompare(b.employee_name));

  t.innerHTML = `<thead><tr>
      <th>Worker</th><th>Job</th><th>Work center</th>
      <th>Qualification</th><th>Regulation</th><th>Status</th><th>Expires</th><th>Evidence</th>
    </tr></thead><tbody>` + rows.map((r) => {
      const st = STATE[r.qualification_state] || STATE.MISSING;
      return `<tr>
        <td>${esc(r.employee_name)}</td>
        <td>${esc(r.job_description)}</td>
        <td>${esc(r.current_work_center || '—')}</td>
        <td>${esc(r.qualification_name)}</td>
        <td class="mono">${esc(r.regulation_reference || '—')}</td>
        <td><span class="pill ${st.cls}">${st.ico} ${esc(r.qualification_state.replace(/_/g, ' ').toLowerCase())}</span></td>
        <td class="mono">${esc(r.expires_on || '—')}</td>
        <td class="mono">${esc(r.evidence_reference || '—')}</td>
      </tr>`;
    }).join('') + '</tbody>';
}

// -------------------------------------------------------------- renewal view

async function loadRenewal() {
  const data = await api(`/api/gate/renewal-pipeline?principal=${encodeURIComponent(principal)}`);
  const b = data.buckets;
  document.getElementById('renewal-tiles').innerHTML =
      tile('stop',    b.LAPSED || 0, 'Lapsed')
    + tile('caution', b.DUE_30 || 0, 'Due in 30 days')
    + tile('watch',   b.DUE_60 || 0, 'Due in 60 days')
    + tile('go',      b.DUE_90 || 0, 'Due in 90 days');

  const t = document.getElementById('renewal-table');
  if (!data.rows.length) {
    t.innerHTML = `<tr><td class="empty">Nothing lapsing within ninety days.</td></tr>`;
    document.getElementById('renewal-bulk').classList.add('hidden');
    return;
  }
  document.getElementById('renewal-bulk').classList.remove('hidden');

  t.innerHTML = `<thead><tr>
      <th></th><th>Worker</th><th>Location</th><th>Department</th><th>Supervisor</th>
      <th>Qualification</th><th>Expires</th><th>Days</th><th>Bucket</th>
    </tr></thead><tbody>` + data.rows.map((r, i) => {
      const bk = BUCKET[r.bucket] || BUCKET.DUE_90;
      return `<tr>
        <td class="pick"><input type="checkbox" class="renewal-pick" data-i="${i}"
              aria-label="Select ${esc(r.employee_name)}"></td>
        <td>${esc(r.employee_name)}</td>
        <td>${esc(r.location)}</td>
        <td>${esc(r.department)}</td>
        <td>${esc(r.supervisor_name || '—')}</td>
        <td>${esc(r.qualification_name)}</td>
        <td class="mono">${esc(r.expires_on)}</td>
        <td class="mono">${r.days_until_expiry}</td>
        <td><span class="pill ${bk.cls}">${bk.ico} ${bk.word}</span></td>
      </tr>`;
    }).join('') + '</tbody>';

  const picks   = () => [...document.querySelectorAll('.renewal-pick:checked')]
                          .map((c) => data.rows[Number(c.dataset.i)]);
  const notify  = document.getElementById('renewal-notify');
  const count   = document.getElementById('renewal-count');
  const all     = document.getElementById('renewal-all');
  const refresh = () => {
    const n = picks().length;
    count.textContent = n ? `${n} selected` : 'none selected';
    notify.disabled = !n;
    notify.textContent = n > 1 ? `Notify ${n} supervisors` : 'Notify supervisor';
  };

  document.querySelectorAll('.renewal-pick').forEach((c) =>
    c.addEventListener('change', refresh));
  all.checked = false;
  all.onchange = () => {
    document.querySelectorAll('.renewal-pick').forEach((c) => { c.checked = all.checked; });
    refresh();
  };
  notify.onclick = async () => {
    const rows = picks();
    notify.disabled = true;
    await notifyRenewals(rows);
    document.querySelectorAll('.renewal-pick').forEach((c) => { c.checked = false; });
    all.checked = false;
    refresh();
  };
  document.getElementById('renewal-export').onclick = () => {
    const sel = picks();
    exportRenewals(sel.length ? sel : data.rows);
  };
  refresh();
}

// ------------------------------------------------------------- overview view

/* Albers equal-area conic, the standard choice for the continental US. Chosen
 * over a plain Mercator because at this latitude range Mercator visibly stretches
 * the north, which misplaces sites relative to one another on the map.
 */
function albers(lon, lat) {
  const d = Math.PI / 180;
  const lat1 = 29.5 * d, lat2 = 45.5 * d;      // standard parallels
  const lat0 = 37.5 * d, lon0 = -96 * d;       // origin
  const n = Math.log(Math.cos(lat1) / Math.cos(lat2)) /
            Math.log(Math.tan(Math.PI / 4 + lat2 / 2) / Math.tan(Math.PI / 4 + lat1 / 2));
  const F = (Math.cos(lat1) * Math.pow(Math.tan(Math.PI / 4 + lat1 / 2), n)) / n;
  const rho  = F / Math.pow(Math.tan(Math.PI / 4 + lat * d / 2), n);
  const rho0 = F / Math.pow(Math.tan(Math.PI / 4 + lat0 / 2), n);
  const theta = n * (lon * d - lon0);
  // SVG y grows downward, so the conic's northward term is negated. Without this
  // the map renders upside down: Seattle below Miami.
  return [rho * Math.sin(theta), rho * Math.cos(theta) - rho0];
}

// Fit the projection to the drawing area using the continental extent
const MAP_W = 960, MAP_H = 600;
const _c = [[-124.7, 24.5], [-66.9, 49.4], [-124.7, 49.4], [-66.9, 24.5]].map(([a, b]) => albers(a, b));
const _xs = _c.map((p) => p[0]), _ys = _c.map((p) => p[1]);
const _x0 = Math.min(..._xs), _x1 = Math.max(..._xs);
const _y0 = Math.min(..._ys), _y1 = Math.max(..._ys);
const _pad = 26;
const _k = Math.min((MAP_W - _pad * 2) / (_x1 - _x0), (MAP_H - _pad * 2) / (_y1 - _y0));
const _ox = (MAP_W - (_x1 - _x0) * _k) / 2 - _x0 * _k;
const _oy = (MAP_H - (_y1 - _y0) * _k) / 2 - _y0 * _k;

const project = (lon, lat) => {
  const [x, y] = albers(lon, lat);
  return [x * _k + _ox, y * _k + _oy];
};

const READY = {
  ACTION_REQUIRED: { cls: 'site-action',  label: 'Action required', color: 'var(--stop)' },
  WATCH:           { cls: 'site-watch',   label: 'Watch',           color: 'var(--watch)' },
  CLEAR:           { cls: 'site-clear',   label: 'Clear',           color: 'var(--go)' },
  NOT_ONBOARDED:   { cls: 'site-pending', label: 'Not yet onboarded', color: '#ffffff' },
};

const COVER = {
  NO_COVER:     { cls: 'stop',    ico: '✕', word: 'No cover' },
  SINGLE_POINT: { cls: 'caution', ico: '◆', word: 'Single point of failure' },
  THIN:         { cls: 'watch',   ico: '▲', word: 'Thin' },
  ADEQUATE:     { cls: 'go',      ico: '✓', word: 'Adequate' },
};

let STATES = null;

async function drawMap(sites) {
  const svg = document.getElementById('map');
  const parts = [];

  if (STATES === null) {
    try { STATES = await (await fetch('/static/data/states.json')).json(); } catch { STATES = []; }
  }

  // State outlines first, so the plant markers sit on land rather than floating
  // in space, which makes the geography hard to read.
  for (const r of STATES) {
    let d = '';
    for (let i = 0; i < r.length; i++) {
      const [x, y] = project(r[i][0], r[i][1]);
      d += (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1);
    }
    parts.push(`<path class="landmass" d="${d}Z" aria-hidden="true"/>`);
  }


  const maxHead = Math.max(...sites.map((s) => s.headcount_estimate || 1));
  const placed = [];

  for (const s of sites) {
    if (s.latitude == null || s.longitude == null) continue;
    const [x, y] = project(Number(s.longitude), Number(s.latitude));
    const r = 4 + 7 * Math.sqrt((s.headcount_estimate || 1) / maxHead);
    const look = s.site_type === 'HEADQUARTERS'
      ? { cls: 'site-hq' } : (READY[s.readiness] || READY.NOT_ONBOARDED);

    if (s.readiness === 'ACTION_REQUIRED') {
      parts.push(`<circle class="site-halo" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${(r + 8).toFixed(1)}" fill="var(--stop)"/>`);
    }
    parts.push(
      `<circle class="site-dot ${look.cls}" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${r.toFixed(1)}"` +
      ` data-site="${esc(s.site_id)}" tabindex="0" role="button"` +
      ` aria-label="${esc(s.label)}, ${esc((READY[s.readiness] || READY.NOT_ONBOARDED).label)}"/>`
    );
    placed.push({ s, x, y, r });
  }

  // Label only what is looked for first, and only where the label will not sit on
  // top of another one. Fifteen labels in the Texas cluster would be unreadable.
  const taken = [];
  const notable = placed.filter((p) =>
    p.s.readiness === 'ACTION_REQUIRED' || p.s.site_type === 'HEADQUARTERS' || p.s.rollout_status === 'IN_FLIGHT');

  for (const p of notable) {
    const right = p.x < MAP_W - 130;
    const lx = p.x + (right ? p.r + 6 : -(p.r + 6));
    const ly = p.y + 3.5;
    const clash = taken.some((t) => Math.abs(t.y - ly) < 12 && Math.abs(t.x - lx) < 96);
    const dy = clash ? 13 : 0;
    taken.push({ x: lx, y: ly + dy });
    parts.push(`<text class="site-label" x="${lx.toFixed(1)}" y="${(ly + dy).toFixed(1)}" text-anchor="${right ? 'start' : 'end'}">${esc(p.s.label)}</text>`);
  }

  svg.innerHTML = parts.join('');

  document.getElementById('map-legend').innerHTML =
    ['ACTION_REQUIRED', 'WATCH', 'CLEAR', 'NOT_ONBOARDED'].map((k) =>
      `<span><i style="background:${READY[k].color};${k === 'NOT_ONBOARDED' ? 'border:1.5px solid #94a2b4' : ''}"></i>${READY[k].label}</span>`
    ).join('')
    + `<span><i style="background:var(--ink)"></i>Headquarters</span>`
    + `<span style="color:var(--ink-faint)">Marker size reflects workforce.</span>`;

  const tip = document.getElementById('map-tip');
  const byId = Object.fromEntries(sites.map((s) => [s.site_id, s]));

  const showTip = (el) => {
    const s = byId[el.dataset.site];
    if (!s) return;
    const rd = READY[s.readiness] || READY.NOT_ONBOARDED;
    const cov = s.coverage_pct != null
      ? `<div>Coverage <b>${s.coverage_pct}%</b> of ${s.people_assessed} assessed</div>`
      : `<div class="tl">No qualification data yet</div>`;
    const gap = s.people_with_gap ? `<div>${s.people_with_gap} with a gap</div>` : '';
    const roll = s.rollout_on
      ? `<div class="tl">${s.rollout_status === 'IN_FLIGHT' ? 'Onboarding' : 'Planned'} ${s.rollout_on}</div>` : '';
    tip.innerHTML = `<b>${esc(s.label)}</b>, ${esc(s.state)}<div class="tl">${esc(rd.label)}</div>${cov}${gap}${roll}`
      + `<div class="tl">~${s.headcount_estimate} people</div>`;
    const wrap = document.getElementById('map-wrap').getBoundingClientRect();
    const box = el.getBoundingClientRect();
    tip.classList.remove('hidden');
    const tw = tip.offsetWidth;
    let left = box.left - wrap.left + box.width / 2 - tw / 2;
    left = Math.max(6, Math.min(left, wrap.width - tw - 6));
    tip.style.left = left + 'px';
    tip.style.top = (box.top - wrap.top - tip.offsetHeight - 10) + 'px';
  };

  svg.querySelectorAll('.site-dot').forEach((el) => {
    el.addEventListener('mouseenter', () => showTip(el));
    el.addEventListener('focus', () => showTip(el));
    el.addEventListener('mouseleave', () => tip.classList.add('hidden'));
    el.addEventListener('blur', () => tip.classList.add('hidden'));
  });
}

async function loadOverview() {
  const d = await api(`/api/overview?principal=${encodeURIComponent(principal)}`);
  window._ov = d;
  document.getElementById('ov-date').textContent = fmtDate(d.as_of);
  const p = d.program;

  const cov = p.coverage_pct == null ? '—' : p.coverage_pct + '%';
  document.getElementById('ov-tiles').innerHTML =
      tile('stop',    p.blocked_tomorrow,     'Blocked from tomorrow’s work')
    + tile('caution', p.supervision_tomorrow, 'Awaiting supervised first performance')
    + tile('',        cov,                    `Coverage, ${p.people_assessed} assessed`)
    + tile('',        `${p.sites_onboarded}/${p.sites_total}`, 'Sites onboarded')
    + tile('',        p.workforce_estimate.toLocaleString(), 'Workforce in scope');

  // Trend leads; the map draws on first open so it measures a visible pane.
  const ovPane = (mode) => {
    if (mode === 'trend') loadTrend().catch((e) => toast(`Trend failed: ${e.message}`));
    if (mode === 'map') drawMap(d.sites).catch((e) => toast(`Map failed: ${e.message}`));
  };
  wireSubtabs('ov-mode', 'ov-pane', ovPane);
  ovPane(document.querySelector('#ov-mode .subtab.active').dataset.mode);

  // Rollout schedule
  const RS = { LIVE: ['go', 'Live'], IN_FLIGHT: ['caution', 'Onboarding'], PLANNED: ['', 'Planned'] };
  document.getElementById('ov-sites').innerHTML = `<thead><tr>
      <th>Site</th><th>State</th><th>Type</th><th>Rollout</th><th>Date</th>
      <th>Workforce</th><th>Assessed</th><th>Coverage</th><th>Readiness</th>
    </tr></thead><tbody>` + d.sites.map((s) => {
      const rs = RS[s.rollout_status] || RS.PLANNED;
      const rd = READY[s.readiness] || READY.NOT_ONBOARDED;
      const rdk = { ACTION_REQUIRED: 'stop', WATCH: 'watch', CLEAR: 'go', NOT_ONBOARDED: '' }[s.readiness] || '';
      return `<tr>
        <td>${esc(s.label)}</td>
        <td class="mono">${esc(s.state)}</td>
        <td>${esc(s.site_type.toLowerCase())}</td>
        <td>${rs[0] ? `<span class="pill ${rs[0]}">${rs[1]}</span>` : `<span class="mono">${rs[1]}</span>`}</td>
        <td class="mono">${esc(s.rollout_on || '—')}</td>
        <td class="mono">${s.headcount_estimate ?? '—'}</td>
        <td class="mono">${s.people_assessed ?? '—'}</td>
        <td class="mono">${s.coverage_pct != null ? s.coverage_pct + '%' : '—'}</td>
        <td>${rdk ? `<span class="pill ${rdk}">${esc(rd.label)}</span>` : `<span class="mono">${esc(rd.label)}</span>`}</td>
      </tr>`;
    }).join('') + '</tbody>';
}


// -------------------------------------------------------------- coverage view

async function loadCoverage() {
  const d = window._ov
    || (window._ov = await api(`/api/overview?principal=${encodeURIComponent(principal)}`));

  const thin   = d.coverage.filter((c) => c.cover_state !== 'ADEQUATE');
  const none_  = thin.filter((c) => c.qualified_now === 0);
  const single = thin.filter((c) => c.qualified_now === 1);

  document.getElementById('cov-tiles').innerHTML =
      tile('stop',    none_.length,  'Credentials with nobody qualified')
    + tile('caution', single.length, 'Resting on a single person')
    + tile('watch',   thin.length,   'Thin overall');

  document.getElementById('ov-cover').innerHTML = thin.length
    ? thin.map((c) => {
        const k = COVER[c.cover_state];
        return `<div class="cover-row">
          <span class="pill ${k.cls}">${k.ico} ${k.word}</span>
          <span class="qn"><b>${esc(c.qualification_name)}</b><div class="loc">${esc(c.location)}</div></span>
          <span class="cnt">${c.qualified_now}</span>
        </div>`;
      }).join('')
    : `<p class="empty">Cover is adequate everywhere assessed.</p>`;

  // Only the genuinely critical gaps get candidate suggestions. Listing every
  // thin credential would bury the two that matter.
  const opp = await api('/api/overview/credential-opportunity?limit=3');
  const gaps = opp.gaps.filter((g) => g.cover_state !== 'THIN').slice(0, 4);

  document.getElementById('ov-opportunity').innerHTML = gaps.length
    ? gaps.map((g) => {
        const k = COVER[g.cover_state];
        const cands = g.candidates.map((c) => {
          const tagCls = c.route === 'RENEW' ? 'renew' : c.route === 'TRAIN' ? 'train' : 'requal';
          const tagTxt = c.route === 'RENEW' ? 'Renewal only'
                       : c.route === 'TRAIN' ? 'New training' : 'Requalify after revocation';
          const warn = c.previously_revoked
            ? `<div class="warn">◆ Previously revoked${c.revoked_reason ? ': ' + esc(c.revoked_reason) : ''}</div>` : '';
          const near = c.already_assigned_to_such_work
            ? `<div class="cj">Already assigned to work requiring it</div>` : '';
          const payload = { ...c };
          const gapMeta = { qualification_id: g.qualification_id, qualification_name: g.qualification_name,
                            location: g.location, qualified_now: g.qualified_now, cover_state: g.cover_state };
          return `<div class="cand ${c.previously_revoked ? 'flagged' : ''}">
            <div class="cn">${esc(c.employee_name)}</div>
            <div class="cj">${esc(c.job_description)} · ${esc(c.department)}</div>
            ${near}
            <div class="cr"><span class="tag ${tagCls}">${tagTxt}</span></div>
            <div class="cj" style="margin-top:4px">Holds ${c.credentials_held} other regulated credential${c.credentials_held === 1 ? '' : 's'}</div>
            ${warn}
            <div class="cand-actions">
              <button class="request"
                      data-cand='${esc(JSON.stringify(payload))}'
                      data-gap='${esc(JSON.stringify(gapMeta))}'>Email supervisor</button>
              <span class="cand-note">${esc(c.supervisor_name || '')}</span>
            </div>
          </div>`;
        }).join('');
        return `<div class="opp">
          <div class="opp-head">
            <span class="pill ${k.cls}">${k.ico} ${k.word}</span>
            <span class="q">${esc(g.qualification_name)}</span>
            <span class="l">${esc(g.location)} · ${g.qualified_now} qualified today</span>
          </div>
          <div class="opp-cands">${cands}</div>
        </div>`;
      }).join('')
    : `<p class="empty">No critical coverage gaps with internal candidates.</p>`;

  document.querySelectorAll('#ov-opportunity button.request').forEach((b) =>
    b.addEventListener('click', () => sendCredentialingRequest(b)));

  initWhatif();
}

// -------------------------------------------------------------- what-if studio

/* The decisioning layer, surfaced. The scenario shows tomorrow's regulated seats
 * and the qualified pool with their model lapse-risk. Solving runs the optimizer
 * live and returns a compliant plan plus the seats it cannot staff and why. */

const WI_CLEAR = {
  NOT_CLEARED:          { cls: 'stop',    word: 'Not cleared' },
  SUPERVISION_REQUIRED: { cls: 'caution', word: 'First performance' },
  CLEARED_EXPIRING:     { cls: 'watch',   word: 'Expiring' },
  CLEARED:              { cls: 'go',      word: 'Cleared' },
};

function riskPill(r) {
  const cls = r >= 0.3 ? 'stop' : r >= 0.1 ? 'caution' : 'go';
  return `<span class="pill ${cls}">lapse risk ${r.toFixed(2)}</span>`;
}

async function initWhatif() {
  const d = await api(`/api/whatif/scenario?principal=${encodeURIComponent(principal)}`);
  window._wi = d;
  document.getElementById('wi-tiles').innerHTML =
      tile('watch', d.current.seats,   'Regulated seats tomorrow')
    + tile('stop',  d.current.exposed, 'Exposed under the current schedule')
    + tile('go',    d.worker_count,    'Qualified workers in the pool');
  document.getElementById('wi-status').textContent =
    `${d.seat_count} seats, ${d.worker_count} qualified workers in scope for ${d.work_date}.`;
  document.getElementById('wi-plan').innerHTML = '';
  document.getElementById('wi-uncovered').innerHTML = '';
  const btn = document.getElementById('wi-solve');
  btn.disabled = d.seat_count === 0;
  btn.onclick = () => solveWhatif(false);
  // The plan is produced by the nightly run, so it is already on screen when the
  // page opens; the button re-plans on demand.
  if (d.seat_count > 0) solveWhatif(true);
}

function eveningBefore(iso) {
  const d = new Date(iso + 'T00:00:00');
  d.setDate(d.getDate() - 1);
  return d.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
}

async function solveWhatif(scheduled) {
  const btn = document.getElementById('wi-solve');
  btn.disabled = true;
  document.getElementById('wi-status').textContent = scheduled ? 'Loading the nightly plan…' : 'Re-planning with CP-SAT…';
  try {
    const d = await api('/api/whatif/solve', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ principal }),
    });
    const s = d.summary;
    document.getElementById('wi-tiles').innerHTML =
        tile('go',      s.covered,          'Seats compliantly staffed')
      + tile('caution', s.exposure_cleared, 'Exposed seats now cleared')
      + tile('stop',    s.uncovered,        'Cannot staff compliantly');
    const w = window._wi || {};
    const when = scheduled
      ? `Nightly run, ${eveningBefore(w.work_date)} at 6:00 PM`
      : `Refreshed at ${new Date().toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`;
    document.getElementById('wi-status').textContent =
      `${when} · ${w.current ? w.current.exposed + ' of ' + w.current.seats + ' seats exposed under the posted schedule · ' : ''}`
      + `total assigned lapse risk ${s.total_assigned_lapse_risk}. Hard compliance rules are constraints, never traded off.`;

    document.getElementById('wi-plan').innerHTML =
      `<div class="wi-h">The plan</div>`
      + d.assignments.map((a) => `
        <div class="cover-row">
          <span class="pill ${a.reassigned_from_scheduled ? 'caution' : 'go'}">
            ${a.reassigned_from_scheduled ? 're-planned' : 'on schedule'}</span>
          <span class="qn"><b>${esc(a.assigned_name)}</b>
            <div class="loc">${esc(a.work_center)} · ${esc(a.qualification)}</div>
            ${a.reassigned_from_scheduled
              ? `<div class="loc">was ${esc(a.scheduled_name)} — ${esc(WI_CLEAR[a.current_clearance]?.word || a.current_clearance)}</div>`
              : ''}
            ${a.assigned_risk_explanation
              ? `<div class="loc why">${esc(a.assigned_risk_explanation)}</div>` : ''}
          </span>
          <span>${riskPill(a.assigned_lapse_risk)}</span>
        </div>`).join('');

    document.getElementById('wi-uncovered').innerHTML = d.uncovered.length
      ? `<div class="wi-h wi-h-stop">Still exposed: act before the shift</div>`
        + d.uncovered.map((u) => `
          <div class="cover-row">
            <span class="pill ${WI_CLEAR[u.current_clearance]?.cls || 'stop'}">
              ${esc(WI_CLEAR[u.current_clearance]?.word || u.current_clearance)}</span>
            <span class="qn"><b>${esc(u.work_center)}</b>
              <div class="loc">${esc(u.qualification)}</div>
              <div class="loc">${esc(u.reason)}</div>
              ${u.remediation ? `<div class="loc fix">▸ ${esc(u.remediation)}</div>` : ''}</span>
          </div>`).join('')
      : `<p class="empty">Every regulated seat can be compliantly staffed.</p>`;
  } catch (e) {
    document.getElementById('wi-status').textContent = `Plan failed: ${e.message}`;
  } finally {
    btn.disabled = false;
  }
}

// ------------------------------------------------------------------ osha view

/* Two modes off one payload.
 *
 * Internal audit leads with findings, which are actionable before an inspection.
 * Inspection mode leads with the roster, since an inspector picks names from it and
 * each pick resolves to evidence. Same data; the ordering differs, not the query.
 */

const AUDIT_STATUS = {
  GAP:                   { cls: 'stop',    ico: '✕', word: 'Credential gap' },
  HAZWORK_EXPIRED:           { cls: 'stop',    ico: '✕', word: 'Authorization expired' },
  EVALUATION_OVERDUE:    { cls: 'caution', ico: '◆', word: 'Evaluation overdue' },
  HAZWORK_REEVAL_OVERDUE: { cls: 'caution', ico: '◆', word: 'Re-evaluation overdue' },
  NO_HAZCOM:             { cls: 'caution', ico: '◆', word: 'No HazCom' },
  SUPERVISOR_NO_30HR:    { cls: 'watch',   ico: '▲', word: 'No 30-hour card' },
  NO_OUTREACH_CARD:      { cls: 'watch',   ico: '▲', word: 'No outreach card' },
  COMPLETE:              { cls: 'go',      ico: '✓', word: 'Complete' },
};

const HAZWORK = {
  QUALIFIED:         { cls: 'go',      ico: '✓', word: 'Qualified' },
  EXPIRING:          { cls: 'watch',   ico: '▲', word: 'Expiring' },
  EXPIRED:           { cls: 'stop',    ico: '✕', word: 'Expired' },
  OVERSIGHT_OVERDUE: { cls: 'caution', ico: '◆', word: 'Oversight overdue' },
  NOT_QUALIFIED:     { cls: 'stop',    ico: '✕', word: 'Not qualified' },
  NOT_APPLICABLE:    { cls: '',        ico: '',  word: 'n/a' },
  NO_RECORD:         { cls: '',        ico: '',  word: '—' },
};

const FINDING_LABEL = {
  CREDENTIAL: 'Credential', PRACTICAL_EVALUATION: 'Practical evaluation',
  OUTREACH_CARD: 'Outreach card', COMPETENT_PERSON: 'Competent person',
  WRITTEN_PROGRAM: 'Written program', HAZCOM: 'Hazard communication',
  OSHA_HAZWORK: 'OSHA high-hazard authorization',
};

let oshaMode = 'findings';

async function loadOsha() {
  const d = await api(`/api/overview/audit?principal=${encodeURIComponent(principal)}`);
  const s = d.summary;

  document.getElementById('osha-lede').innerHTML = oshaMode !== 'inspection'
    ? 'Open findings as of <strong>' + fmtDate(d.as_of) + '</strong>, ordered by severity.'
    : 'Roster and evidence as of <strong>' + fmtDate(d.as_of) + '</strong>. Each name resolves to a card serial, trainer and evidence reference.';

  document.getElementById('osha-tiles').innerHTML = oshaMode !== 'inspection'
    ? tile('stop',    s.critical,              'Critical findings')
      + tile('caution', s.findings - s.critical,  'Other findings')
      + tile(s.checks_failed ? 'stop' : 'go', s.checks_failed, 'Site checks failed today')
      + tile('watch',   s.programs_overdue,      'Programs overdue for review')
      + tile('',        s.hazwork_issues,            'OSHA high-hazard issues')
      + tile(s.acknowledgments_missing ? 'caution' : 'go', s.acknowledgments_missing, 'Credentials with nothing signed')
    : tile('go',   s.complete,            'Workers fully documented')
      + tile('stop', s.workers - s.complete, 'Workers with a gap')
      + tile('',     s.workers,             'Active workers in scope')
      + tile(s.recordables_unqualified ? 'stop' : '', s.recordables_unqualified,
             'Recordables where a credential was not held');

  wireSubtabs('osha-mode', 'osha-pane', (mode) => { oshaMode = mode; runLoader('osha'); });

  const mx = document.getElementById('matrix-export');
  if (mx && !mx.dataset.wired) {
    mx.dataset.wired = '1';
    mx.addEventListener('click', () => exportMatrix(d.matrix));
  }

  // ---- internal ----------------------------------------------------------
  const fEl = document.getElementById('osha-findings');
  fEl.innerHTML = d.findings.length
    ? d.findings.map((f) => `<div class="finding">
        <span class="sev s${f.severity_rank}">${f.severity_rank === 1 ? 'Critical' : f.severity_rank === 2 ? 'Major' : 'Minor'}</span>
        <div class="fb">
          <div class="ft">${esc(f.finding)}</div>
          <div class="fw">${esc(f.why)}</div>
          <div class="fm">${esc(FINDING_LABEL[f.finding_type] || f.finding_type)}
            · ${esc(f.location)}${f.employee_name ? ' · ' + esc(f.employee_name) : ''}</div>
        </div>
      </div>`).join('')
    : `<p class="empty">No findings in scope.</p>`;

  const pEl = document.getElementById('osha-programs');
  pEl.innerHTML = `<thead><tr>
      <th>Program</th><th>Standard</th><th>Version</th><th>Last reviewed</th><th>Owner</th><th>Document</th><th>Status</th>
    </tr></thead><tbody>` + d.programs.map((p) => `<tr>
      <td>${esc(p.name)}</td>
      <td class="mono">${esc(p.standard_ref || '—')}</td>
      <td class="mono">${esc(p.version || '—')}</td>
      <td class="mono">${esc(p.last_reviewed_on || '—')}</td>
      <td>${esc(p.owner_name || '—')}</td>
      <td class="mono">${esc(p.document_ref || '—')}</td>
      <td>${p.overdue ? '<span class="pill stop">✕ Overdue</span>' : '<span class="pill go">✓ Current</span>'}</td>
    </tr>`).join('') + '</tbody>';

  const CHK = {
    PASS:           { cls: 'go',    ico: '✓', word: 'Pass' },
    FAIL:           { cls: 'stop',  ico: '✕', word: 'Fail' },
    NOT_APPLICABLE: { cls: '',      ico: '',  word: 'n/a' },
    NOT_CHECKED:    { cls: 'watch', ico: '▲', word: 'Not checked' },
  };
  const cEl = document.getElementById('osha-checklist');
  const checks = d.checklist || [];
  cEl.innerHTML = checks.length
    ? `<thead><tr>
        <th>Inspection item</th><th>Standard</th><th>Applies to</th><th>Status</th>
        <th>Field condition</th><th>Corrective action</th>
      </tr></thead><tbody>` + checks.map((c) => {
        const k = CHK[c.status] || CHK.NOT_CHECKED;
        const cap = c.corrective_action_id
          ? `<span class="mono">${esc(c.corrective_action_id)}</span>`
            + `<div class="loc">${esc(c.corrective_owner || '')}${c.corrective_due_on ? ' · due ' + esc(c.corrective_due_on) : ''}`
            + `${c.corrective_status ? ' · ' + esc(c.corrective_status.replace('_',' ').toLowerCase()) : ''}</div>`
          : `<span class="mono">—</span>`;
        return `<tr>
          <td>${esc(c.area)}</td>
          <td class="mono">${esc(c.standard_ref || '—')}</td>
          <td class="mono">${esc(c.applies_to.replace('_',' ').toLowerCase())}</td>
          <td><span class="pill ${k.cls}">${k.ico} ${k.word}</span></td>
          <td>${esc(c.field_note || '—')}</td>
          <td>${cap}</td>
        </tr>`;
      }).join('') + '</tbody>'
    : `<tr><td class="empty">No checklist results in scope.</td></tr>`;


  // Worker sign-off. A completion record says the system believes someone was
  // trained; a signed acknowledgment is what an inspector is actually shown.
  const ACK_KIND = {
    TRAINING_RECEIPT: 'Training receipt',
    POLICY_ATTESTATION: 'Policy attestation',
    HAZARD_BRIEFING: 'Hazard briefing',
    SUPERVISED_FIRST_PERFORMANCE: 'Supervised first performance',
    REQUALIFICATION: 'Requalification',
  };
  const aEl = document.getElementById('osha-acks');
  const missing = d.missing_acknowledgments || [];
  const acks = d.acknowledgments || [];

  const missingBlock = missing.length ? `
    <div class="bc-label" style="padding:14px 18px 4px">Held with nothing signed</div>
    ${missing.map((m) => `<div class="finding">
      <span class="sev s2">Major</span>
      <div class="fb">
        <div class="ft">${esc(m.employee_name)} — ${esc(m.qualification_name)}</div>
        <div class="fw">Credential is current, but no signed acknowledgment exists to show an inspector.</div>
        <div class="fm">${esc(m.regulation_reference || '')} · issued ${esc(m.issued_on)} · ${esc(m.evidence_reference || '')}</div>
      </div>
    </div>`).join('')}` : '';

  const proxyNote = s.acknowledgments_proxy
    ? `<div class="bc-label" style="padding:14px 18px 4px">${s.acknowledgments_proxy} signed by proxy</div>`
    : '';

  aEl.innerHTML = missingBlock + proxyNote + (acks.length
    ? `<div class="tablewrap"><table id="osha-acks-table"></table></div>`
    : `<p class="empty">No signed acknowledgments in scope.</p>`);

  if (acks.length) {
    renderTable(
      document.getElementById('osha-acks-table'),
      ['Worker', 'Subject', 'Kind', 'Signed', 'Method', 'Signed by', 'Trainer', 'Reference'],
      acks,
      (a) => cell(a.employee_name) + cell(a.subject)
        + `<td class="mono">${esc(ACK_KIND[a.kind] || a.kind)}</td>`
        + mono(a.signed_date)
        + `<td>${a.is_proxy
              ? pill({ cls: 'caution', ico: '◆' }, 'proxy')
              : `<span class="mono">${esc(a.method.replace(/_/g, ' ').toLowerCase())}</span>`}</td>`
        + cell(a.proxy_for ? `${a.signed_by_name} for ${a.proxy_for}` : a.signed_by_name)
        + mono(a.trainer_name) + mono(a.document_ref),
    );
  }

  const iEl = document.getElementById('osha-incidents');
  iEl.innerHTML = d.incidents.length
    ? `<thead><tr>
        <th>Case</th><th>Date</th><th>Worker</th><th>Classification</th>
        <th>Away / restricted</th><th>Required at the time</th><th>Qualified?</th>
      </tr></thead><tbody>` + d.incidents.map((i) => `<tr>
        <td class="mono">${esc(i.case_number)}</td>
        <td class="mono">${esc(i.incident_on)}</td>
        <td>${esc(i.employee_name || '—')}</td>
        <td class="mono">${esc((i.classification || '').replace(/_/g, ' ').toLowerCase())}</td>
        <td class="mono">${i.days_away}/${i.days_restricted}</td>
        <td>${esc(i.required_at_time || '—')}</td>
        <td>${i.unheld_at_time
              ? `<span class="pill stop">✕ Not held: ${esc(i.unheld_at_time)}</span>`
              : '<span class="pill go">✓ All held</span>'}</td>
      </tr>`).join('') + '</tbody>'
    : `<tr><td class="empty">No recordable incidents in scope.</td></tr>`;

  // ---- inspection --------------------------------------------------------
  const locs = [...new Set(d.matrix.map((m) => m.location))];
  document.getElementById('osha-meta').innerHTML = [
    ['Site', locs.join(', ') || '—'],
    ['Date of review', d.as_of],
    ['Reviewer', principal],
    ['Workers on roster', d.matrix.length],
    ['Fully documented', `${s.complete} of ${s.workers}`],
    ['Open findings', s.findings],
  ].map(([k, v]) => `<div><div class="mk">${esc(k)}</div><div class="mv">${esc(v)}</div></div>`).join('');

  const mEl = document.getElementById('osha-matrix');
  mEl.innerHTML = `<thead><tr>
      <th>Worker</th><th>Job title</th><th>OSHA 10 / 30</th><th>Trainer</th>
      <th>LOTO</th><th>HazCom</th><th>Hazard credentials</th><th>Practical evaluation</th>
      <th>OSHA high-hazard</th><th>Competent person for</th><th>Status</th>
    </tr></thead><tbody>` + d.matrix.map((m) => {
      const st = AUDIT_STATUS[m.audit_status] || AUDIT_STATUS.COMPLETE;
      const card = (on, serial) => on
        ? `<span class="mono">${esc(on)}</span><br><span class="mono" style="font-size:.6875rem">${esc(serial || '')}</span>`
        : `<span class="mono">—</span>`;
      const creds = m.credentials_required
        ? (m.missing_list
            ? `<span class="pill stop">✕ ${m.credentials_held}/${m.credentials_required}</span><div class="loc">${esc(m.missing_list)}</div>`
            : `<span class="pill go">✓ ${m.credentials_held}/${m.credentials_required}</span>`)
        : `<span class="mono">n/a</span>`;
      const prac = m.practical_overdue_count
        ? `<span class="pill caution">◆ Overdue</span><div class="loc">${esc(m.practical_overdue_list)}</div>`
        : `<span class="mono">—</span>`;
      const fr = HAZWORK[m.hazwork_status] || HAZWORK.NO_RECORD;
      // "Not applicable" is stated with its reason rather than left blank: an
      // inspector asks why someone has no high-hazard authorization, and silence reads
      // as a missing record.
      const hazworkCell = m.hazwork_regulated
        ? `<span class="pill ${fr.cls}">${fr.ico} ${fr.word}</span>`
          + (m.hazwork_craft ? `<div class="loc">${esc(m.hazwork_craft)}</div>` : '')
        : `<span class="mono">n/a</span>`
          + (m.hazwork_na_reason ? `<div class="loc">${esc(m.hazwork_na_reason)}</div>` : '');
      const cardCell = (m.osha30_on || m.osha10_on)
        ? (m.osha30_on ? `<span class="mono">30hr ${esc(m.osha30_serial || '')}</span><div class="loc">${esc(m.osha30_on)}</div>` : '')
          + (m.osha10_on ? `<span class="mono">10hr ${esc(m.osha10_serial || '')}</span><div class="loc">${esc(m.osha10_on)}</div>` : '')
        : `<span class="pill watch">▲ none</span>`;
      return `<tr>
        <td>${esc(m.employee_name)}</td>
        <td>${esc(m.job_description)}${m.is_supervisory ? '<div class="loc">supervisory</div>' : ''}</td>
        <td>${cardCell}</td>
        <td class="mono">${esc(m.osha30_trainer || m.osha10_trainer || '—')}</td>
        <td class="mono">${esc((m.loto_role || '—').toLowerCase())}</td>
        <td>${m.hazcom_trained ? '<span class="pill go">✓</span>' : '<span class="pill caution">◆ none</span>'}</td>
        <td>${creds}</td>
        <td>${prac}</td>
        <td>${hazworkCell}</td>
        <td>${esc(m.competent_for || '—')}</td>
        <td><span class="pill ${st.cls}">${st.ico} ${st.word}</span></td>
      </tr>`;
    }).join('') + '</tbody>';

}

// -------------------------------------------------------------- training view

const AUD = {
  PLANT:  { cls: 'watch', word: 'Plant' },
  OFFICE: { cls: '',      word: 'Office' },
  ALL:    { cls: 'go',    word: 'All staff' },
};

async function loadTraining() {
  const d = await api('/api/overview/training');
  const s = d.summary;
  document.getElementById('tr-tiles').innerHTML =
      tile('go', s.closing_gaps, 'Sessions closing a live gap')
    + tile('',   s.next_30,      'Within 30 days')
    + tile('',   s.plant,        'Open to plant staff')
    + tile('',   s.office,       'Open to office staff');

  const t = document.getElementById('tr-table');
  if (!d.rows.length) {
    t.innerHTML = `<tr><td class="empty">No sessions scheduled.</td></tr>`;
    return;
  }

  t.innerHTML = `<thead><tr>
      <th>Session</th><th>Audience</th><th>Delivery</th><th>Site</th>
      <th>Starts</th><th>In</th><th>Seats</th><th>Impact</th>
    </tr></thead><tbody>` + d.rows.map((r) => {
      const a = AUD[r.audience] || AUD.PLANT;
      const impact = r.would_close_gaps
        ? `<span class="pill go">✓ Closes ${r.would_close_gaps} gap${r.would_close_gaps === 1 ? '' : 's'}</span>`
        : r.relieves_thin_cover
          ? `<span class="pill watch">▲ Adds depth</span>`
          : `<span class="mono">—</span>`;
      const reg = r.is_regulated ? ` <span class="mono">· regulated</span>` : '';
      return `<tr>
        <td>${esc(r.title)}${reg}</td>
        <td>${a.cls ? `<span class="pill ${a.cls}">${a.word}</span>` : `<span class="mono">${a.word}</span>`}</td>
        <td class="mono">${esc(r.delivery.replace('_', ' ').toLowerCase())}</td>
        <td>${esc(r.site_label || '—')}</td>
        <td class="mono">${esc(r.starts_on)}</td>
        <td class="mono">${r.days_away}d</td>
        <td class="mono">${r.enrolled}/${r.seats}</td>
        <td>${impact}</td>
      </tr>`;
    }).join('') + '</tbody>';
}

// -------------------------------------------------------- credential card view

/* The artifact an inspector is shown on the floor.
 *
 * Design constraint: one verdict, readable standing up at arm's length, with the
 * blocking reason first. Everything else is secondary.
 */

const CARD_STATE = {
  CURRENT:      { cls: 'go',      ico: '✓' },
  EXPIRING:     { cls: 'watch',   ico: '▲' },
  EXPIRED:      { cls: 'stop',    ico: '✕' },
  REVOKED:      { cls: 'stop',    ico: '✕' },
  OUT_OF_SCOPE: { cls: 'stop',    ico: '✕' },
  MISSING:      { cls: 'stop',    ico: '✕' },
};

async function loadCard() {
  const sel = document.getElementById('card-who');

  if (!sel.dataset.wired) {
    const people = await api(`/api/gate/roster-lookup?principal=${encodeURIComponent(principal)}`);
    if (!people.length) {
      document.getElementById('card-body').innerHTML =
        `<p class="empty">No workers in your scope.</p>`;
      return;
    }
    sel.innerHTML = people.map((p) =>
      `<option value="${esc(p.employee_id)}">${esc(p.employee_name)} — ${esc(p.job_description)}</option>`
    ).join('');
    sel.dataset.wired = '1';
    sel.addEventListener('change', () => renderCard(sel.value));
  }
  await renderCard(sel.value);

  const btn = document.getElementById('card-export');
  if (btn && !btn.dataset.wired) {
    btn.dataset.wired = '1';
    btn.addEventListener('click', () => exportCard(sel.value));
  }
}

// The card as plain text rather than a spreadsheet: it is one person's record and
// gets read, not sorted.
async function exportCard(employeeId) {
  const d = await api(`/api/gate/credential-card/${encodeURIComponent(employeeId)}?principal=${encodeURIComponent(principal)}`);
  if (!d.found) return;
  const p = d.person;
  const L = [];
  L.push(`QUALIFICATION RECORD`);
  L.push(`Generated ${d.as_of} by ${principal}`);
  L.push('');
  L.push(`${p.employee_name} — ${p.job_description}, ${p.department}`);
  L.push(`${p.location} · Supervisor ${p.supervisor_name || '—'} · ID ${p.employee_id}`);
  L.push('');
  L.push(`Regulated credentials held: ${d.summary.regulated_held} of ${d.summary.regulated_total}`);
  if (d.summary.blocking) L.push(`NOT CLEARED — ${d.summary.blocking} credential(s) not held`);
  if (d.summary.evaluations_overdue) L.push(`Practical evaluation overdue`);
  L.push('');
  L.push('HAZARD CREDENTIALS');
  d.credentials.forEach((c) => L.push(
    `  ${c.qualification_name} — ${c.state.replace(/_/g, ' ').toLowerCase()}`
    + (c.expires_on ? ` — expires ${c.expires_on}` : '')
    + (c.regulation_reference ? ` — ${c.regulation_reference}` : '')
    + (c.evidence_reference ? ` — ${c.evidence_reference}` : '')));
  if (d.evaluations.length) {
    L.push('');
    L.push('PRACTICAL EVALUATIONS');
    d.evaluations.forEach((e) => L.push(
      `  ${e.qualification_name} — ${e.overdue ? 'OVERDUE' : 'current'} — last ${e.evaluated_on}`
      + ` — every ${e.practical_evaluation_months} months — ${e.evaluator_name || ''}`));
  }
  L.push('');
  L.push('OSHA OUTREACH CARD');
  if (p.osha30_on) L.push(`  OSHA 30-hour — ${p.osha30_serial || ''} — ${p.osha30_on} — ${p.osha30_trainer || ''}`);
  if (p.osha10_on) L.push(`  OSHA 10-hour — ${p.osha10_serial || ''} — ${p.osha10_on} — ${p.osha10_trainer || ''}`);
  if (!p.osha30_on && !p.osha10_on) L.push('  No card on record');
  if (p.hazwork_regulated) {
    L.push('');
    L.push('OSHA HIGH-HAZARD AUTHORIZATION');
    L.push(`  ${p.hazwork_craft || 'Regulated high-hazard role'} — ${p.hazwork_status.replace(/_/g, ' ').toLowerCase()}`
      + (p.hazwork_expires_on ? ` — expires ${p.hazwork_expires_on}` : ''));
  }
  L.push('');
  L.push('OTHER');
  L.push(`  Lockout / tagout: ${(p.loto_role || 'none').toLowerCase()}`);
  L.push(`  Hazard communication: ${p.hazcom_trained ? 'trained ' + (p.hazcom_trained_on || '') : 'no record'}`);
  if (p.competent_for) L.push(`  Competent person: ${p.competent_for}`);
  if (d.acknowledgments && d.acknowledgments.length) {
    L.push('');
    L.push('SIGNED ACKNOWLEDGMENTS');
    d.acknowledgments.forEach((a) => L.push(
      `  ${a.signed_date} — ${a.subject} — signed by ${a.signed_by_name}`
      + (a.is_proxy ? ' (proxy)' : '') + (a.document_ref ? ` — ${a.document_ref}` : '')));
  }
  const safe = p.employee_name.replace(/[^a-z0-9]+/gi, '-').toLowerCase();
  download(`qualification-record-${safe}-${stamp()}.txt`, L.join('\n'), 'text/plain');
  toast('Record exported.');
}

async function renderCard(employeeId) {
  const el = document.getElementById('card-body');
  const d = await api(`/api/gate/credential-card/${encodeURIComponent(employeeId)}?principal=${encodeURIComponent(principal)}`);

  if (!d.found) {
    el.innerHTML = `<p class="empty">${esc(d.reason)}</p>`;
    return;
  }

  const p = d.person, s = d.summary;
  const initials = p.employee_name.split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase();

  // One verdict. Blocking beats overdue evaluation beats clear.
  const verdict = s.blocking
    ? { cls: 'stop', ico: '✕', text: `Not cleared — ${s.blocking} credential${s.blocking === 1 ? '' : 's'} not held` }
    : s.evaluations_overdue
      ? { cls: 'caution', ico: '◆', text: 'Practical evaluation overdue' }
      : { cls: 'go', ico: '✓', text: `Cleared — ${s.regulated_held} of ${s.regulated_total} regulated credentials current` };

  // Blocking credentials first: the reason someone is stopped should not require
  // scrolling past the ones that are fine.
  const order = { MISSING: 1, EXPIRED: 2, REVOKED: 3, OUT_OF_SCOPE: 4, EXPIRING: 5, CURRENT: 6 };
  const creds = [...d.credentials].sort((a, b) =>
    (order[a.state] || 9) - (order[b.state] || 9) || a.qualification_name.localeCompare(b.qualification_name));

  const credRows = creds.map((c) => {
    const k = CARD_STATE[c.state] || CARD_STATE.MISSING;
    const detail = c.state === 'REVOKED'
        ? `Revoked${c.revoked_reason ? ': ' + esc(c.revoked_reason) : ''}`
      : c.state === 'OUT_OF_SCOPE'
        ? `Authorized for ${esc(c.scoped_to || 'another site')}`
      : c.state === 'EXPIRED'
        ? `Lapsed ${Math.abs(c.days_until_expiry)} days ago`
      : c.state === 'EXPIRING'
        ? `Expires in ${c.days_until_expiry} days`
        : 'Current';
    return `<div class="bc-row ${k.cls}">
      <span class="bi">${k.ico}</span>
      <span class="bn">
        <div class="bt">${esc(c.qualification_name)}</div>
        <div class="bs">${detail}${c.regulation_reference ? ' · ' + esc(c.regulation_reference) : ''}</div>
      </span>
      <span class="bd">${esc(c.evidence_reference || '')}<br>${esc(c.expires_on || '')}</span>
    </div>`;
  }).join('');

  // Practical evaluations sit apart from credentials because they are a separate
  // duty; a current certificate with an overdue evaluation is still a citation.
  const evalRows = d.evaluations.length ? `
    <div class="bc-label">Practical evaluations</div>
    ${d.evaluations.map((e) => `<div class="bc-row ${e.overdue ? 'caution' : 'go'}">
        <span class="bi">${e.overdue ? '◆' : '✓'}</span>
        <span class="bn">
          <div class="bt">${esc(e.qualification_name)}</div>
          <div class="bs">${e.overdue ? 'Overdue' : 'Current'} · every ${e.practical_evaluation_months} months · ${esc(e.evaluator_name || '')}</div>
        </span>
        <span class="bd">${esc(e.evaluated_on)}</span>
      </div>`).join('')}` : '';

  const cardRow = (label, on, serial, trainer) => on ? `<div class="bc-row go">
      <span class="bi">✓</span>
      <span class="bn">
        <div class="bt">${label}</div>
        <div class="bs">${esc(serial || '')}${trainer ? ' · ' + esc(trainer) : ''}</div>
      </span>
      <span class="bd">${esc(on)}</span>
    </div>` : '';

  const outreach = (p.osha10_on || p.osha30_on)
    ? `<div class="bc-label">OSHA outreach card</div>
       ${cardRow('OSHA 30-hour', p.osha30_on, p.osha30_serial, p.osha30_trainer)}
       ${cardRow('OSHA 10-hour', p.osha10_on, p.osha10_serial, p.osha10_trainer)}`
    : `<div class="bc-label">OSHA outreach card</div>
       <div class="bc-row stop"><span class="bi">✕</span>
         <span class="bn"><div class="bt">No card on record</div></span></div>`;

  const hazworkRow = p.hazwork_regulated
    ? `<div class="bc-label">OSHA high-hazard</div>
       <div class="bc-row ${p.hazwork_status === 'QUALIFIED' ? 'go' : p.hazwork_status === 'EXPIRED' ? 'stop' : 'caution'}">
         <span class="bi">${p.hazwork_status === 'QUALIFIED' ? '✓' : p.hazwork_status === 'EXPIRED' ? '✕' : '◆'}</span>
         <span class="bn">
           <div class="bt">${esc(p.hazwork_craft || 'Regulated high-hazard role')}</div>
           <div class="bs">${esc(p.hazwork_status.replace(/_/g, ' ').toLowerCase())}</div>
         </span>
         <span class="bd">${esc(p.hazwork_expires_on || '')}</span>
       </div>`
    : '';

  const other = `
    <div class="bc-label">Other</div>
    <div class="bc-row ${p.loto_role === 'NONE' ? '' : 'go'}">
      <span class="bi">${p.loto_role === 'NONE' ? '·' : '✓'}</span>
      <span class="bn"><div class="bt">Lockout / tagout</div>
        <div class="bs">${esc((p.loto_role || 'none').toLowerCase())}</div></span>
    </div>
    <div class="bc-row ${p.hazcom_trained ? 'go' : 'caution'}">
      <span class="bi">${p.hazcom_trained ? '✓' : '◆'}</span>
      <span class="bn"><div class="bt">Hazard communication</div>
        <div class="bs">${p.hazcom_trained ? 'Trained' : 'No record'}</div></span>
      <span class="bd">${esc(p.hazcom_trained_on || '')}</span>
    </div>
    ${p.competent_for ? `<div class="bc-row go"><span class="bi">✓</span>
      <span class="bn"><div class="bt">Competent person</div>
        <div class="bs">${esc(p.competent_for)}</div></span></div>` : ''}`;

  const signed = (d.acknowledgments || []).length ? `
    <div class="bc-label">Signed acknowledgments</div>
    ${d.acknowledgments.slice(0, 4).map((a) => `<div class="bc-row ${a.is_proxy ? 'caution' : 'go'}">
      <span class="bi">${a.is_proxy ? '◆' : '✓'}</span>
      <span class="bn"><div class="bt">${esc(a.subject)}</div>
        <div class="bs">${a.is_proxy ? 'Signed by proxy — ' + esc(a.signed_by_name) : 'Signed by ' + esc(a.signed_by_name)}${a.trainer_name ? ' · trainer ' + esc(a.trainer_name) : ''}</div></span>
      <span class="bd">${esc(a.signed_date)}</span>
    </div>`).join('')}` : `
    <div class="bc-label">Signed acknowledgments</div>
    <div class="bc-row caution"><span class="bi">◆</span>
      <span class="bn"><div class="bt">Nothing signed</div>
        <div class="bs">No acknowledgment on record for this worker.</div></span></div>`;

  const shift = d.next_shift.length ? `
    <div class="bc-label">Next scheduled shift</div>
    ${d.next_shift.slice(0, 1).map((n) => `<div class="bc-row ${n.clearance === 'NOT_CLEARED' ? 'stop' : n.clearance === 'SUPERVISION_REQUIRED' ? 'caution' : 'go'}">
      <span class="bi">${n.clearance === 'NOT_CLEARED' ? '✕' : n.clearance === 'SUPERVISION_REQUIRED' ? '◆' : '✓'}</span>
      <span class="bn"><div class="bt">${esc(n.work_center_desc)}</div>
        <div class="bs">${esc(n.reason)}</div></span>
      <span class="bd">${esc(n.work_date)}</span>
    </div>`).join('')}` : '';

  el.innerHTML = `<div class="badge-card">
    <div class="bc-head">
      <span class="bc-avatar">${esc(initials)}</span>
      <span class="bc-who">
        <div class="bc-name">${esc(p.employee_name)}</div>
        <div class="bc-role">${esc(p.job_description)} · ${esc(p.department)}</div>
        <div class="bc-meta">${esc(p.location)} · Supervisor ${esc(p.supervisor_name || '—')} · ID ${esc(p.employee_id)}</div>
      </span>
    </div>
    <div class="bc-verdict ${verdict.cls}"><span class="vi">${verdict.ico}</span>${esc(verdict.text)}</div>
    <div class="bc-section">
      ${shift}
      <div class="bc-label">Hazard credentials</div>
      ${credRows || '<div class="bc-row"><span class="bn"><div class="bs">None required.</div></span></div>'}
      ${evalRows}
      ${outreach}
      ${hazworkRow}
      ${other}
      ${signed}
    </div>
    <div class="bc-foot">
      <span>Shown as of ${esc(d.as_of)}</span>
      <span>Viewed by ${esc(principal)}</span>
    </div>
  </div>`;
}

// ------------------------------------------------------------------ trend view

/* Direction rather than level.
 *
 * Three readings are deliberately kept on separate charts, because collapsing
 * them tells the reader something untrue:
 *
 *   - Network coverage falls when a site onboards: a plant's worth of unassessed
 *     people joins the denominator. Same-site coverage runs alongside so that
 *     reads as progress rather than regression.
 *   - Supervised first performances may rise, and that is a success count. The
 *     number that should fall is the ones that went ahead unsupervised.
 *   - Falling exposure is ambiguous without volume: the gate working and the
 *     schedule feed stopping look identical. Scheduled shifts sit behind the
 *     exposure line as bars.
 */

const CH = { w: 720, h: 190, l: 38, r: 12, t: 12, b: 26 };

function scales(rows, keys) {
  const vals = rows.flatMap((r) => keys.map((k) => r[k]).filter((v) => v !== null && v !== undefined))
                   .map(Number);
  const max = Math.max(1, ...vals);
  const n = Math.max(1, rows.length - 1);
  return {
    x: (i) => CH.l + (i / n) * (CH.w - CH.l - CH.r),
    y: (v) => CH.t + (1 - Number(v) / max) * (CH.h - CH.t - CH.b),
    max,
  };
}

function path(rows, key, s) {
  let d = '', started = false;
  rows.forEach((r, i) => {
    const v = r[key];
    if (v === null || v === undefined) return;
    d += (started ? 'L' : 'M') + s.x(i).toFixed(1) + ' ' + s.y(v).toFixed(1);
    started = true;
  });
  return d;
}

function axes(rows, s, fmt = (v) => v) {
  const ticks = [0, 0.5, 1].map((f) => s.max * f);
  const grid = ticks.map((v) =>
    `<line class="tr-grid" x1="${CH.l}" y1="${s.y(v).toFixed(1)}" x2="${CH.w - CH.r}" y2="${s.y(v).toFixed(1)}"/>`
    + `<text class="tr-axis" x="${CH.l - 6}" y="${(s.y(v) + 3.5).toFixed(1)}" text-anchor="end">${fmt(Math.round(v * 10) / 10)}</text>`
  ).join('');
  // Label the ends and the middle only; sixteen dates would be unreadable.
  const idx = [0, Math.floor(rows.length / 2), rows.length - 1];
  const labels = [...new Set(idx)].map((i) => {
    const d = new Date(rows[i].week_of + 'T00:00:00');
    const txt = d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    const anchor = i === 0 ? 'start' : i === rows.length - 1 ? 'end' : 'middle';
    return `<text class="tr-axis" x="${s.x(i).toFixed(1)}" y="${CH.h - 8}" text-anchor="${anchor}">${txt}</text>`;
  }).join('');
  return grid + labels;
}

// Mark the week a site came online, since that is what explains the coverage dip.
function onboardMarkers(rows, s) {
  const out = [];
  for (let i = 1; i < rows.length; i++) {
    if (rows[i].sites_onboarded > rows[i - 1].sites_onboarded) {
      const x = s.x(i).toFixed(1);
      out.push(`<line class="tr-marker" x1="${x}" y1="${CH.t}" x2="${x}" y2="${CH.h - CH.b}"/>`
        + `<text class="tr-marker-label" x="${x}" y="${CH.t - 2}" text-anchor="middle">site onboarded</text>`);
    }
  }
  return out.join('');
}

function chart(title, why, rows, spec, keyRows) {
  const s = scales(rows, spec.keys);
  const bars = spec.bars
    ? rows.map((r, i) => {
        const bw = Math.max(2, (CH.w - CH.l - CH.r) / rows.length - 3);
        const v = r[spec.bars] || 0;
        const bs = scales(rows, [spec.bars]);
        return `<rect class="tr-bar" x="${(s.x(i) - bw / 2).toFixed(1)}" y="${bs.y(v).toFixed(1)}"
                 width="${bw.toFixed(1)}" height="${(CH.h - CH.b - bs.y(v)).toFixed(1)}" rx="1.5"/>`;
      }).join('')
    : '';
  const lines = spec.keys.map((k, n) =>
    `<path class="tr-line ${'abc'[n]}" d="${path(rows, k, s)}"/>`).join('');
  const last = rows[rows.length - 1];
  const dots = spec.keys.map((k, n) =>
    last[k] === null || last[k] === undefined ? '' :
    `<circle class="tr-dot ${'ab'[n] || 'b'}" cx="${s.x(rows.length - 1).toFixed(1)}"
             cy="${s.y(last[k]).toFixed(1)}" r="3.5"/>`).join('');

  return `<div class="tr-chart">
    <h4>${esc(title)}</h4>
    <p class="why">${esc(why)}</p>
    <svg viewBox="0 0 ${CH.w} ${CH.h}" role="img" aria-label="${esc(title)}">
      ${bars}${axes(rows, s, spec.fmt)}${spec.markers ? onboardMarkers(rows, s) : ''}${lines}${dots}
    </svg>
    <div class="tr-key">${keyRows}</div>
  </div>`;
}

const keyItem = (cls, label) =>
  `<span><i style="background:${cls}"></i>${esc(label)}</span>`;

async function loadTrend() {
  const d = await api(`/api/overview/trend?principal=${encodeURIComponent(principal)}`);
  const n = d.network;
  if (!n.length) {
    document.getElementById('tr-cards').innerHTML = '<p class="empty">No history yet.</p>';
    return;
  }
  const s = d.summary;

  // Direction, stated rather than left to be read off a line.
  // Movement stated from the first non-null week to the last, in the metric's own
  // units, with the direction named rather than left to a sign.
  const dir = (from, to, lowerIsBetter, unit = '') => {
    if (from === null || from === undefined || to === null || to === undefined)
      return { cls: 'flat', text: 'not enough history' };
    const a = Number(from), b = Number(to);
    if (Math.abs(b - a) < 0.05) return { cls: 'flat', text: `flat at ${b}${unit}` };
    const fell = b < a;
    const better = lowerIsBetter ? fell : !fell;
    return { cls: better ? 'good' : 'bad',
             text: `${fell ? 'down' : 'up'} from ${a}${unit} over ${s.weeks} weeks` };
  };

  const expo = dir(s.blocked_per_100_first, s.blocked_per_100_last, true);
  const close = dir(s.days_to_close_first, s.days_to_close_last, true, ' days');

  document.getElementById('tr-cards').innerHTML = `<div class="tr-cards">
    <div class="tr-card">
      <div class="k">Blocked per 100 shifts</div>
      <div class="v">${s.blocked_per_100_last ?? '—'}</div>
      <div class="d ${expo.cls}">${esc(expo.text)}</div>
    </div>
    <div class="tr-card">
      <div class="k">Unsupervised first performance</div>
      <div class="v">${s.unsupervised_last ?? '—'}</div>
      <div class="d ${s.unsupervised_last === 0 ? 'good' : 'bad'}">${s.unsupervised_last === 0 ? 'none this week' : 'still occurring'}</div>
    </div>
    <div class="tr-card">
      <div class="k">Coverage</div>
      <div class="v">${s.coverage_last ?? '—'}%</div>
      <div class="d flat">${s.baseline_coverage_last ?? '—'}% at the first site</div>
    </div>
    <div class="tr-card">
      <div class="k">Median days to close</div>
      <div class="v">${s.days_to_close_last ?? '—'}</div>
      <div class="d ${close.cls}">${esc(close.text)}</div>
    </div>
  </div>`;

  document.getElementById('tr-charts').innerHTML =
    chart('Exposure', 
          'Blocked shifts per hundred scheduled. Bars are scheduled volume, so a drop caused by a quiet week or a stalled feed is visible rather than flattering.',
          n, { keys: ['blocked_per_100_shifts'], bars: 'scheduled_shifts', fmt: (v) => v },
          keyItem('var(--stop)', 'Blocked per 100 shifts') + keyItem('#dde4ec', 'Scheduled shifts'))
  + chart('First performance',
          'Supervised first performances are a success count and may rise. The red line is the one that should reach zero.',
          n, { keys: ['unsupervised_first_performance', 'supervision_required'] },
          keyItem('var(--stop)', 'Went ahead unsupervised') + keyItem('var(--go)', 'Supervised, caught'))
  + chart('Coverage',
          'Network coverage dips when a site onboards, because unassessed people join the denominator. The dashed line is the first site alone, which keeps climbing.',
          n, { keys: ['coverage_pct', 'baseline_coverage_pct'], markers: true, fmt: (v) => v + '%' },
          keyItem('var(--stop)', 'Network') + keyItem('var(--go)', 'First site only'))
  + chart('Findings',
          'Open findings against the median days taken to close one.',
          n, { keys: ['findings_open', 'median_days_to_close'] },
          keyItem('var(--stop)', 'Open findings') + keyItem('var(--go)', 'Median days to close'));

  // The derived table, which is the point about their existing data
  const rows = (d.derived || []).slice(-40).reverse();
  renderTable(
    document.getElementById('tr-derived'),
    ['Work date', 'Location', 'People scheduled', 'Requirements', 'Met', 'People blocked', 'Met %'],
    rows,
    (r) => mono(r.work_date) + cell(r.location) + mono(r.people_scheduled)
         + mono(r.requirements) + mono(r.requirements_met)
         + `<td>${r.people_blocked ? pill({ cls: 'stop', ico: '✕' }, String(r.people_blocked)) : '<span class="mono">0</span>'}</td>`
         + mono(r.met_pct !== null ? r.met_pct + '%' : '—'),
    'No scheduled history in scope.',
  );
}

// ------------------------------------------------------------------ home

function loadHome() {
  document.getElementById('home-month').textContent =
    new Date().toLocaleDateString(undefined, { month: 'long', year: 'numeric' });

  const p = (window._ov && window._ov.program) || null;
  const cards = document.getElementById('home-cards');
  cards.innerHTML = !p ? '' : `
    <div class="hcard stop">
      <div class="hk">Blocked tomorrow</div>
      <div class="hv">${p.blocked_tomorrow}</div>
      <div class="hn">Scheduled into work they are not cleared for</div>
    </div>
    <div class="hcard caution">
      <div class="hk">First performance</div>
      <div class="hv">${p.supervision_tomorrow}</div>
      <div class="hn">Needs a supervisor present before the shift</div>
    </div>
    <div class="hcard dark">
      <div class="hk">Rollout</div>
      <div class="hv">${p.sites_onboarded} of ${p.sites_total}</div>
      <div class="hn">Sites onboarded · ${p.workforce_estimate.toLocaleString()} people in scope</div>
    </div>`;

  // Six, so the grid reads as two rows of three. The sixth is deliberately the
  // non-plant side: general training is phase two of the rollout, and showing it
  // as a first-class view signals that the same qualification model extends
  // beyond the shop floor.
  // Every destination except Home, Ask and Documentation, which are entered by
  // name rather than in sequence.
  const PATH = [
    ['overview', 'Network overview',      'Facility readiness across the plant network, on the map.'],
    ['shift',    'Pre-shift clearance',   'Tomorrow’s schedule checked against what each job and work center requires.'],
    ['coverage', 'Coverage & what-if',    'Thin credentials, and the internal candidates closest to closing each gap.'],
    ['site',     'Audit roster',          'Who must hold what, whether they hold it, and the evidence reference.'],
    ['card',     'Credential card',       'One worker’s qualifications, sized for a tablet on the floor.'],
    ['osha',     'OSHA audit',            'Internal findings, and the roster an inspector spot-checks.'],
    ['renewal',  'Renewals',              'Credentials lapsed or lapsing within ninety days.'],
    ['training', 'Upcoming training',     'Scheduled sessions, plant and office.'],
  ];
  document.getElementById('home-path').innerHTML = PATH.map(([v, t, d], i) =>
    `<button class="pcard" data-goto="${v}">
       <span class="pn">${i + 1}</span>
       <div class="pt">${t}</div>
       <div class="pd">${d}</div>
     </button>`).join('');

  document.querySelectorAll('[data-goto]').forEach((b) =>
    b.addEventListener('click', () => show(b.dataset.goto)));
}

// ------------------------------------------------------------------- ask

const askState = { started: false, engine: 'governed' };

function bubble(role, html) {
  return `<div class="msg ${role}">
      <span class="who-ico">${role === 'bot' ? '✦' : (window._initials || 'You')}</span>
      <div class="bubble">${html}</div>
    </div>`;
}

async function askSend(q) {
  const thread = document.getElementById('ask-thread');
  thread.insertAdjacentHTML('beforeend', bubble('me', esc(q)));
  thread.insertAdjacentHTML('beforeend',
    bubble('bot', `<span class="thinking"><i></i><i></i><i></i></span>`));
  thread.scrollTop = thread.scrollHeight;

  const pending = thread.lastElementChild;
  try {
    const r = await api('/api/ask', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ question: q, principal, engine: askState.engine }),
    });
    let extra = '';
    if (r.engine === 'genie') {
      // Genie returns the SQL it ran, so the answer is inspectable.
      if (r.sql) {
        const tbl = (r.columns && r.columns.length && r.rows && r.rows.length)
          ? `<table class="genie-tbl"><thead><tr>${r.columns.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead>`
            + `<tbody>${r.rows.slice(0, 8).map((row) => `<tr>${row.map((v) => `<td>${esc(v ?? '—')}</td>`).join('')}</tr>`).join('')}</tbody></table>`
          : '';
        extra = `<details class="genie-sql"><summary>SQL Genie ran${r.row_count ? ` · ${r.row_count} rows` : ''}</summary>`
          + `<pre>${esc(r.sql)}</pre>${tbl}</details>`;
      }
    }
    const jump = r.view && VIEWS.includes(r.view)
      ? `<button class="jump" data-goto="${esc(r.view)}">Open ${esc(VIEW_LABEL[r.view] || r.view)} →</button>`
      : '';
    const fell = r.genie_error
      ? `<div class="genie-fallback">Genie unavailable; answered from governed queries.</div>` : '';
    pending.querySelector('.bubble').innerHTML = esc(r.answer) + fell + extra + jump;
    pending.querySelectorAll('[data-goto]').forEach((b) =>
      b.addEventListener('click', () => show(b.dataset.goto)));
  } catch (e) {
    pending.querySelector('.bubble').textContent = `Could not answer: ${e.message}`;
  }
  thread.scrollTop = thread.scrollHeight;
}

const VIEW_LABEL = {
  overview: 'network overview', shift: 'pre-shift clearance',
  coverage: 'coverage and what-if', site: 'audit roster', renewal: 'renewals',
};

async function loadAsk() {
  const thread = document.getElementById('ask-thread');
  if (!askState.started) {
    askState.started = true;
    thread.innerHTML = bubble('bot',
      'Ask about tomorrow’s exposure, site audit readiness, thin cover, or who is one '
      + 'credential away from closing a gap. Answers are limited to your scope.');

    const { suggestions, genie_available } = await api('/api/ask/suggestions');
    document.getElementById('ask-suggest').innerHTML =
      suggestions.map((s) => `<button class="sugg">${esc(s)}</button>`).join('');
    document.querySelectorAll('#ask-suggest .sugg').forEach((b) =>
      b.addEventListener('click', () => askSend(b.textContent)));

    // Engine toggle: governed intents (always) or Genie over the gold tables.
    const mode = document.getElementById('asst-mode');
    if (genie_available && mode) {
      const setEngine = (eng) => {
        askState.engine = eng;
        mode.textContent = eng === 'genie' ? 'Genie · gold tables' : 'governed SQL';
        document.querySelectorAll('#ask-engine button').forEach((x) =>
          x.classList.toggle('on', x.dataset.eng === eng));
      };
      const bar = document.createElement('div');
      bar.id = 'ask-engine';
      bar.innerHTML = `<span>Answer with</span>`
        + `<button data-eng="governed" class="on">Governed queries</button>`
        + `<button data-eng="genie">Genie</button>`;
      document.getElementById('ask-suggest').before(bar);
      bar.querySelectorAll('button').forEach((b) =>
        b.addEventListener('click', () => setEngine(b.dataset.eng)));
    }

    document.getElementById('ask-sources').innerHTML =
      '<span>Grounded in</span>'
      + ['v_shift_clearance', 'v_site_roster', 'v_coverage', 'v_credential_opportunity', 'v_renewal_pipeline']
        .map((v) => `<span class="src">gate.${v}</span>`).join('');

    document.getElementById('ask-form').addEventListener('submit', (e) => {
      e.preventDefault();
      const input = document.getElementById('ask-input');
      const q = input.value.trim();
      if (!q) return;
      input.value = '';
      askSend(q);
    });
  }
}

// ----------------------------------------------------------------- docs

const DOCS = {
  model: `
<h3>What this adds, and what it leaves alone</h3>
<p>A learning management system records courses, enrolments and completions. This layer sits beside
that and answers a different question: <b>may this person perform this work, today, and can we prove
it.</b> Course delivery, content and assessment stay where they are.</p>
<h3>Three tables carry the logic</h3>
<ul>
  <li><code>qualification</code> — what credentials exist, which are regulated, which demand a
      supervised first performance, whether they travel between sites, how long they last.</li>
  <li><code>workcenter_requirement</code> and <code>job_requirement</code> — what a work center or a
      job demands. Effective-dated, because an audit asks what was required <em>at the time</em>.</li>
  <li><code>first_performance</code> — whether a supervised first performance happened and who
      supervised it. This row is the audit evidence that the control was applied.</li>
</ul>
<h3>Why a credential has a scope</h3>
<p>Some travel with the person. Some are authorized per site or per asset — confined space entry is
commonly permit-specific to a vessel. Treating every credential as portable produces someone who is
qualified on paper for a space they have never been authorized to enter.</p>`,

  logic: `
<h3>Two different notions of “first time”</h3>
<p>These are distinct, and conflating them generates false alerts.</p>
<ul>
  <li><b>First time at this work center.</b> Useful context, but not on its own a reason to require
      supervision: a welder moving between two welding bays is not doing anything new.</li>
  <li><b>First time performing.</b> Has this person ever worked anywhere that demanded this
      credential? This is the one that gates. For site-scoped credentials the site is part of the
      question.</li>
</ul>
<p>Only days where the person actually <b>held</b> the credential count as experience. Work performed
while unqualified is an exposure, not training, and must not be allowed to discharge the control that
exists to catch it.</p>
<h3>Why the check runs before the shift</h3>
<p>The schedule is known in advance, so the check runs against the forward schedule rather than at
clock-in, giving a supervisor time to act before the shift.</p>
<h3>The case a clock-in gate cannot catch</h3>
<p>Because the source records scheduled and actual work center separately, a further case is visible:
someone cleared at the start of the shift who moves into work they are not qualified for. A gate that
evaluates only at clock-in clears them and never looks again.</p>
<h3>Site and supervisor are the access model</h3>
<p>A supervisor sees their crew, a plant manager sees their site, safety sees everything, an
unknown principal sees nothing. Every view the predicate touches must expose both location and
supervisor, or the caller is forced to weaken the predicate and a crew supervisor silently gains
sight of the whole site.</p>`,

  connect: `
<h3>Three source tables</h3>
<p>Everything here runs on stand-ins whose column names mirror the real ones, so the views transfer
with only the schema qualifier changed.</p>
<ul>
  <li><code>employee_current_workcenter_assignment</code> — current work center per person</li>
  <li><code>employee_scheduled_workcenter_history</code> — scheduled and actual work center by date</li>
  <li><code>hr_employee</code> — job, department, site, supervisor</li>
</ul>
<h3>Assumption worth confirming</h3>
<p>All three refresh daily. If the HR side lagged on a monthly snapshot, a mid-month role change would
be invisible to the gate for up to a month — and role change driving new requirements is a stated
requirement. The join works either way, but the freshness claim would need restating.</p>
<h3>Where the credential records should live</h3>
<p><code>employee_qualification</code> is materialized here so the demo runs standalone. Against real
data it should be a view over the existing certification records, not a second copy.</p>`,

  dataflow: `
<h3>Where the answers come from</h3>
<p>A business user is right to ask whether a new system can be trusted. Every verdict in ClearShift is
derived from records the plant already keeps, in systems it already runs. It reads those systems, it is
not a second source of truth.</p>
<svg viewBox="0 0 920 384" role="img" style="width:100%;height:auto;margin:16px 0;font-family:inherit"
     aria-label="Data flows from the HR system, the workforce scheduler and the learning system, is governed on Databricks, and becomes the ClearShift views.">
  <defs>
    <marker id="df-arw" markerWidth="9" markerHeight="9" refX="6" refY="3" orient="auto">
      <path d="M0 0L6 3L0 6z" fill="var(--ink-faint)"/>
    </marker>
  </defs>

  <text x="145" y="22" text-anchor="middle" fill="var(--ink-faint)" font-size="12" font-weight="700" letter-spacing="1">SYSTEMS YOU ALREADY RUN</text>
  <text x="410" y="22" text-anchor="middle" fill="var(--ink-faint)" font-size="12" font-weight="700" letter-spacing="1">GOVERNED</text>
  <text x="730" y="22" text-anchor="middle" fill="var(--ink-faint)" font-size="12" font-weight="700" letter-spacing="1">WHAT YOU SEE</text>

  <rect x="20" y="40" width="250" height="80" rx="10" fill="var(--card)" stroke="var(--line)"/>
  <text x="40" y="72" fill="var(--ink)" font-size="16" font-weight="700">HR system</text>
  <text x="40" y="98" fill="var(--ink-soft)" font-size="13">Employees, roles, supervisors</text>

  <rect x="20" y="136" width="250" height="80" rx="10" fill="var(--card)" stroke="var(--line)"/>
  <text x="40" y="168" fill="var(--ink)" font-size="16" font-weight="700">Workforce scheduler</text>
  <text x="40" y="194" fill="var(--ink-soft)" font-size="13">Who works which seat tomorrow</text>

  <rect x="20" y="232" width="250" height="80" rx="10" fill="var(--card)" stroke="var(--line)"/>
  <text x="40" y="264" fill="var(--ink)" font-size="16" font-weight="700">Learning system (LMS)</text>
  <text x="40" y="290" fill="var(--ink-soft)" font-size="13">Certifications, training, expiry</text>

  <rect x="330" y="56" width="160" height="256" rx="12" fill="var(--page)" stroke="var(--line)" stroke-dasharray="4 4"/>
  <text x="410" y="96" text-anchor="middle" fill="var(--ink)" font-size="15" font-weight="700">Databricks</text>
  <text x="410" y="150" text-anchor="middle" fill="var(--ink-soft)" font-size="13">Ingested</text>
  <text x="410" y="180" text-anchor="middle" fill="var(--ink-soft)" font-size="13">Cleaned</text>
  <text x="410" y="210" text-anchor="middle" fill="var(--ink-soft)" font-size="13">Effective-dated</text>
  <text x="410" y="240" text-anchor="middle" fill="var(--ink-soft)" font-size="13">Access-scoped</text>

  <rect x="560" y="48"  width="340" height="54" rx="10" fill="var(--go-bg)" stroke="var(--go)" stroke-opacity=".35"/>
  <text x="584" y="80" fill="var(--ink)" font-size="15" font-weight="600">Pre-shift clearance</text>
  <rect x="560" y="114" width="340" height="54" rx="10" fill="var(--go-bg)" stroke="var(--go)" stroke-opacity=".35"/>
  <text x="584" y="146" fill="var(--ink)" font-size="15" font-weight="600">Audit roster &amp; OSHA evidence</text>
  <rect x="560" y="180" width="340" height="54" rx="10" fill="var(--go-bg)" stroke="var(--go)" stroke-opacity=".35"/>
  <text x="584" y="212" fill="var(--ink)" font-size="15" font-weight="600">Crew plan (What-if)</text>
  <rect x="560" y="246" width="340" height="54" rx="10" fill="var(--go-bg)" stroke="var(--go)" stroke-opacity=".35"/>
  <text x="584" y="278" fill="var(--ink)" font-size="15" font-weight="600">Credential card</text>

  <g fill="none" stroke="var(--ink-faint)" stroke-width="1.5" marker-end="url(#df-arw)">
    <path d="M270 80  C302 80  300 118 326 122"/>
    <path d="M270 176 L326 184"/>
    <path d="M270 272 C302 272 300 248 326 246"/>
    <path d="M492 120 C526 120 524 75  556 75"/>
    <path d="M492 150 C526 150 524 141 556 141"/>
    <path d="M492 216 C526 216 524 207 556 207"/>
    <path d="M492 246 C526 246 524 273 556 273"/>
  </g>

  <text x="460" y="360" text-anchor="middle" fill="var(--ink-soft)" font-size="14" font-style="italic">Every verdict traces back to your own records. Nothing here is invented.</text>
</svg>
<p style="color:var(--ink-soft);font-size:.9rem">HR says who people are, the scheduler says where they are assigned, the learning system says what they
are qualified to do. ClearShift joins the three and checks tomorrow against them. The same records an
auditor would ask for are the ones the verdict is built from.</p>`,

  osha: `
<h3>What this is built on, and what it is not</h3>
<p><b>OSHA does not publish a certification report format.</b> There is no single
master template an inspector hands over. What follows separates the parts taken from
the standards, the parts taken from an OSHA worksheet, and the parts that are a
proposal, so a safety professional can check the work rather than take it on trust.</p>

<h3>Verified against the standards</h3>
<p>Read on osha.gov and reflected in the logic:</p>
<ul>
  <li><b>29 CFR 1910.178(l)(4)(iii)</b> — an evaluation of each powered industrial
      truck operator's performance at least once every three years. This is why a
      practical evaluation is tracked separately from the credential: a current
      certificate with an overdue evaluation is still a finding, and a
      certificate-only view cannot see it.</li>
  <li><b>29 CFR 1910.146</b> — permit-required confined space training before initial
      assignment, on a change of duties, and when a new hazard is introduced. This is
      why the model triggers on assignment rather than on a calendar.</li>
  <li><b>Employer certification of training</b> — both standards above require the
      employer to certify that training was accomplished. This is why signed
      acknowledgments exist alongside completion records.</li>
  <li><b>29 CFR 1910.147 / .146 / .119</b>: Lockout/Tagout, permit-required confined
      space and Process Safety Management reach only employees whose duties include that
      regulated high-hazard work, not general assembly. This is why the matrix records
      <i>not applicable</i> with a reason rather than leaving a blank.</li>
</ul>
<p>Each credential carries its own citation, visible in the Glossary tab, so any of
this can be checked directly.</p>

<h3>Taken from the OSHA VPP worksheet</h3>
<p>Structure follows the Voluntary Protection Programs on-site evaluation worksheet,
Section IV, Safety and Health Training. That worksheet asks how training requirements
are determined, whether instructors are qualified, and whether workers understand the
hazards of their site, which is the shape the findings list reports against.</p>

<h3>A proposal, not a standard</h3>
<p>These are design decisions and should be argued with:</p>
<ul>
  <li><b>The four sub-tabs.</b> Findings, site conditions, records and incidents, and
      the inspection roster are an organization of what an inspector asks for, not a
      format OSHA defines.</li>
  <li><b>Internal audit against inspection readiness.</b> Same data, ordered
      differently: findings first when there is time to fix them, roster first when
      someone is on site. That split is a judgment about how the two jobs differ.</li>
  <li><b>Severity ranking.</b> Critical, major and minor are this model's, not a
      regulatory scale.</li>
  <li><b>The daily site checklist.</b> Lockout/tagout staging, confined-space permits
      and hot-work fire watch are drawn from common plant safety practice rather than a
      single published checklist.</li>
</ul>

<h3>Worth confirming before this is relied on</h3>
<ul>
  <li>Whether the safety team already has a report format. Matching theirs is better
      than introducing this one.</li>
  <li><b>29 CFR 1910.94</b> is attached to abrasive blasting. That section covers
      ventilation broadly, so the precise paragraph should be confirmed.</li>
  <li>Which employees fall inside regulated high-hazard work (LOTO, confined space,
      hot work), which depends on assigned duties rather than the job title.</li>
  <li>Whether competent person designations are required for hazards beyond the four
      flagged here.</li>
</ul>
<p>Nothing here should be treated as legal or compliance advice.</p>`,

  gaps: `
<h3>Known gaps</h3>
<p>Where this model is incomplete or untested.</p>
<ul>
  <li><b>The denominator is harder than the numerator.</b> “Everyone at this site” is the difficult
      part, not the certificate lookup. HR headcount misses contractors, transfers and temporary
      staff, and a regulator does not care about employment status if the person is on site doing the
      work.</li>
  <li><b>Alert volume is untested.</b> A daily digest of everything gets filtered to junk within two
      weeks. Thresholds need tuning against real volumes.</li>
  <li><b>Two hierarchies disagree.</b> HR holds the supervisor of record; the timekeeping system holds
      who is actually supervising a work center on a shift. This uses HR. Which should drive alert
      routing is a real decision.</li>
  <li><b>Asset-scoped credentials are modeled but not exercised.</b> The scope column supports
      per-vessel authorization; the seed data does not demonstrate it.</li>
  <li><b>No renewal booking.</b> The pipeline identifies who needs scheduling. It does not schedule.</li>
  <li><b>Synthetic data throughout.</b> Roughly a dozen people. Nothing here demonstrates behavior at
      plant scale.</li>
</ul>
<h3>Data</h3>
<p>Facility names are real and public. Every person, identifier, credential and schedule row is
invented.</p>`,
};

/* The glossary is fetched rather than written into the prose, because the terms are
 * data. A plant that calls something else something else can correct the mapping
 * without an edit to the application.
 */
async function renderGlossary() {
  const el = document.getElementById('doc-body');
  el.innerHTML = '<p>Loading…</p>';
  const d = await api('/api/overview/glossary');

  const intro = `
<h3>How a credential is named</h3>
<p>The word people use on the floor and the name in the standard often share nothing.
A <b>forklift</b> is a <b>powered industrial truck</b>; <b>welding</b> is <b>hot work</b>.
The mapping below is held as data, so the assistant and the search can resolve either
form, and a site that uses different words can correct it without changing the
application.</p>
<h3>What each column means</h3>
<ul>
  <li><b>Scope</b> — whether the credential travels with the person, or is authorized
      per site or per asset. Confined space entry is commonly permit-specific.</li>
  <li><b>Valid for</b> — how long before it lapses. Blank means it does not expire.</li>
  <li><b>Supervised first performance</b> — whether the first occasion of this work
      must be supervised, separately from holding the credential.</li>
  <li><b>Practical evaluation</b> — a recurring hands-on evaluation required by the
      standard in addition to the credential. A current certificate with an overdue
      evaluation is still a finding.</li>
  <li><b>Competent person</b> — whether the standard expects a named person
      designated in writing for this hazard at each site.</li>
</ul>`;

  const rows = d.rows.map((r) => `<tr>
      <td><b>${esc(r.name)}</b>${r.is_regulated ? '' : '<div class="loc">not regulated</div>'}</td>
      <td class="mono">${esc(r.regulation_reference || '—')}</td>
      <td class="gloss-terms">${esc(r.common_terms || '—')}${r.abbreviations ? ` · <b>${esc(r.abbreviations)}</b>` : ''}</td>
      <td class="mono">${esc(r.scope.replace(/_/g, ' ').toLowerCase())}</td>
      <td class="mono">${r.validity_months ? r.validity_months + ' mo' : '—'}</td>
      <td>${r.requires_supervised_first_performance ? '<span class="pill caution">◆ yes</span>' : '<span class="mono">—</span>'}</td>
      <td>${r.practical_evaluation_months ? `<span class="pill watch">▲ every ${r.practical_evaluation_months} mo</span>` : '<span class="mono">—</span>'}</td>
      <td>${r.requires_competent_person ? '<span class="pill watch">▲ yes</span>' : '<span class="mono">—</span>'}</td>
      <td class="mono">${r.work_centers_requiring} wc · ${r.jobs_requiring} job</td>
    </tr>`).join('');

  el.innerHTML = intro + `
    <div class="tablewrap" style="margin-top:18px">
      <table id="doc-glossary">
        <thead><tr>
          <th>Credential</th><th>Standard</th><th>Also called</th><th>Scope</th>
          <th>Valid for</th><th>Supervised first</th><th>Practical evaluation</th>
          <th>Competent person</th><th>Required by</th>
        </tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
}

function loadDocs() {
  const render = (k) => {
    if (k === 'glossary') {
      renderGlossary().catch((e) => {
        document.getElementById('doc-body').innerHTML =
          `<p>Could not load the glossary: ${esc(e.message)}</p>`;
      });
      return;
    }
    document.getElementById('doc-body').innerHTML = DOCS[k];
  };
  const tabs = document.querySelectorAll('#doc-tabs .subtab');
  if (!tabs[0].dataset.wired) {
    tabs.forEach((t) => {
      t.dataset.wired = '1';
      t.addEventListener('click', () => {
        tabs.forEach((x) => x.classList.toggle('active', x === t));
        render(t.dataset.doc);
      });
    });
  }
  render(document.querySelector('#doc-tabs .subtab.active').dataset.doc);
}

// ------------------------------------------------------------------- wiring

const LOADERS = {
  home: loadHome, overview: loadOverview, shift: loadShift,
  coverage: loadCoverage, site: loadSite, card: loadCard, osha: loadOsha, renewal: loadRenewal,
  training: loadTraining,
  ask: loadAsk, docs: loadDocs,
};
let current = 'home';

function runLoader(view) {
  // Loaders are a mix of sync and async; normalize so one failure path covers both.
  Promise.resolve()
    .then(() => LOADERS[view]())
    .catch((e) => toast(`Load failed: ${e.message}`));
}

/* Each view is a route with its own URL, so a section can be linked, bookmarked,
 * reloaded and reached with the back button. The sections are separate modules
 * that happen to share a shell, rather than one document with hidden parts.
 */
const VIEWS = ['home', 'overview', 'shift', 'coverage', 'site', 'card',
               'osha', 'renewal', 'training', 'ask', 'docs'];

const PAGE_TITLE = {
  home: 'ClearShift',
  overview: 'Network overview', shift: 'Pre-shift clearance',
  coverage: 'Coverage & what-if', site: 'Audit roster', card: 'Credential card',
  osha: 'OSHA audit', renewal: 'Renewals', training: 'Upcoming training',
  ask: 'Ask ClearShift', docs: 'Documentation',
};

function viewFromUrl() {
  const v = (location.hash || '').replace(/^#\/?/, '').split('?')[0];
  return VIEWS.includes(v) ? v : 'home';
}

function show(view, opts = {}) {
  if (!VIEWS.includes(view)) view = 'home';
  current = view;

  // The URL is the source of truth for which section is open.
  const target = `#/${view}`;
  if (!opts.fromUrl && location.hash !== target) {
    history.pushState({ view }, '', target);
  }
  document.title = view === 'home'
    ? PAGE_TITLE.home : `${PAGE_TITLE[view]} · ClearShift`;

  document.querySelectorAll('.nav-item').forEach((t) => {
    const on = t.dataset.view === view;
    t.classList.toggle('active', on);
    t.setAttribute('aria-current', on ? 'page' : 'false');
  });
  document.querySelectorAll('.view').forEach((s) =>
    s.classList.toggle('hidden', s.id !== `view-${view}`));

  // Reset scroll, and move focus to the heading so the change is announced and
  // keyboard users land in the new section rather than back at the nav.
  window.scrollTo({ top: 0, behavior: 'instant' });
  const sec = document.getElementById(`view-${view}`);
  const h = sec && sec.querySelector('h1, h2');
  if (h) { h.setAttribute('tabindex', '-1'); h.focus({ preventScroll: true }); }

  runLoader(view);
}

// The badge exists so an exposure is visible from any page, not only the one
// that reports it.
async function refreshBadge() {
  try {
    const d = await api(`/api/gate/shift-clearance?principal=${encodeURIComponent(principal)}`);
    const n = d.summary.not_cleared;
    const el = document.getElementById('nav-badge-shift');
    el.textContent = n;
    el.classList.toggle('hidden', !n);
  } catch { /* a missing badge should never break the page */ }
  try {
    const a = await api(`/api/overview/audit?principal=${encodeURIComponent(principal)}`);
    const el = document.getElementById('nav-badge-osha');
    el.textContent = a.summary.critical;
    el.classList.toggle('hidden', !a.summary.critical);
  } catch { /* ditto */ }
}

function setScopeFooter(scopes) {
  const s = scopes.find((x) => x.principal === principal);
  const scopeTxt = !s ? '—'
    : s.scope_type === 'ALL' ? 'All sites'
    : s.scope_type === 'SITE' ? s.scope_value.replace(/ - Plant.*$/, '')
    : `Crew ${s.scope_value}`;
  const role = !s ? '' : s.scope_type === 'ALL' ? 'Corporate safety'
    : s.scope_type === 'SITE'
      ? (/headquarters/i.test(s.scope_value || '') ? 'Corporate' : 'Plant manager')
      : 'Manager';
  const person = principal.split('.').slice(-1)[0].replace(/^./, (c) => c.toUpperCase());
  const initials = (role === 'Corporate safety' ? 'CS' : person.slice(0, 2)).toUpperCase();
  window._initials = initials;
  document.getElementById('foot-scope').textContent = scopeTxt;
  document.getElementById('foot-name').textContent = person;
  document.getElementById('foot-role').textContent = role;
  document.getElementById('foot-initials').textContent = initials;
}

async function init() {
  // Headquarters office scopes (the HQ site and its Finance crew) served corporate
  // learning only; site safety starts at the plant.
  const OFFICE_CREWS = ['50301'];
  const scopes = (await api('/api/gate/principals'))
    .filter((s) => !(s.scope_type === 'SITE' && /headquarters/i.test(s.scope_value || '')))
    .filter((s) => !(s.scope_type === 'CREW' && OFFICE_CREWS.includes(s.scope_value)));
  const sel = document.getElementById('principal');

  const label = (s) => {
    if (s.scope_type === 'ALL') return 'Corporate safety — all sites';
    if (s.scope_type === 'SITE') {
      const hq = /headquarters/i.test(s.scope_value || '');
      return `${hq ? 'Corporate' : 'Plant manager'} — ${s.scope_value.replace(/ - (Plant|Headquarters).*$/, '')}`;
    }
    return `Manager — ${SUPERVISOR_NAME[s.scope_value] || 'crew ' + s.scope_value}`;
  };

  sel.innerHTML = scopes.map((s) =>
    `<option value="${esc(s.principal)}">${esc(label(s))}</option>`).join('');

  // Open on the site that is mid-rollout, since that is where the data lives.
  const inFlight = scopes.find((s) => s.scope_type === 'SITE' && /peoria/i.test(s.scope_value || ''));
  const preferred = inFlight || scopes.find((s) => s.scope_type === 'SITE') || scopes[0];
  principal = preferred.principal;
  sel.value = principal;
  setScopeFooter(scopes);

  sel.addEventListener('change', () => {
    principal = sel.value;
    setScopeFooter(scopes);
    window._ov = null;
    askState.started = false;
    const cw = document.getElementById('card-who');
    if (cw) { cw.dataset.wired = ''; cw.innerHTML = ''; }
    document.getElementById('ask-thread').innerHTML = '';
    refreshBadge();
    runLoader(current);
  });

  document.querySelectorAll('.nav-item').forEach((t) =>
    t.addEventListener('click', () => show(t.dataset.view)));

  // Home reads the overview payload, so fetch it before first paint
  window._ov = await api(`/api/overview?principal=${encodeURIComponent(principal)}`);
  refreshBadge();

  // Open whatever the URL asks for, so a shared link lands on the right section.
  show(viewFromUrl(), { fromUrl: true });
  window.addEventListener('popstate', () => show(viewFromUrl(), { fromUrl: true }));
}

init().catch((e) => toast(`Startup failed: ${e.message}`));
