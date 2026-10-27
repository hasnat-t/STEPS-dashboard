// STEPS Supervisor Remarks dashboard: serves the page and refreshes its data
// from the Taleemabad data service (MCP over HTTP) once a day.
const http = require('http');
const db = require('./db');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT) || 3000;
// The Taleemabad data service (MCP over HTTP). Set it in the host's environment; it is never kept in the code.
const MCP_URL = process.env.MCP_URL || '';
const MCP_USER = process.env.TALEEMABAD_USER || '';
const MCP_TOKEN = process.env.TALEEMABAD_API_TOKEN || ''; // only needed if the data service turns on strict auth
const RULE_VERSION = process.env.RULE_VERSION || 'v0.39.1';
const REFRESH_TOKEN = process.env.REFRESH_TOKEN || '';
// Daily refresh times in Pakistan time, "HH:MM" comma-separated.
const REFRESH_TIMES_PKT = (process.env.REFRESH_TIMES_PKT || '07:13,14:13')
  .split(',').map((t) => t.trim().match(/^(\d{1,2}):(\d{2})$/)).filter(Boolean)
  .map((m) => ({ h: Number(m[1]), m: Number(m[2]) }))
  .filter((t) => t.h < 24 && t.m < 60);
if (!REFRESH_TIMES_PKT.length) throw new Error('REFRESH_TIMES_PKT has no valid HH:MM times');
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const CACHE_FILE = path.join(DATA_DIR, 'teachers.json');
const PUBLIC_DIR = path.join(__dirname, 'public');

const SQL = fs.readFileSync(path.join(__dirname, 'sql', 'refresh.sql'), 'utf8');
const ATTENDANCE_SQL = fs.readFileSync(path.join(__dirname, 'sql', 'attendance.sql'), 'utf8');
const TEACHER_ATTENDANCE_SQL = fs.readFileSync(path.join(__dirname, 'sql', 'teacher_attendance.sql'), 'utf8');
const CLASS_REGISTERS_SQL = fs.readFileSync(path.join(__dirname, 'sql', 'class_registers.sql'), 'utf8');
const FICO_SQL = fs.readFileSync(path.join(__dirname, 'sql', 'fico_scores.sql'), 'utf8');
const FICO_DOMAINS = ['tsk', 'hlp', 'se', 'lpf'];
const TRENDS_SQL = fs.readFileSync(path.join(__dirname, 'sql', 'trends.sql'), 'utf8');
const DC_LESSONS_SQL = fs.readFileSync(path.join(__dirname, 'sql', 'dc_lessons.sql'), 'utf8');
const ATTENDANCE_FIELDS = ['t_days_marked', 't_present', 't_absent', 't_leave', 't_teachers_marked', 't_dates_marked',
  's_class_days', 's_classes_marked', 's_teachers_marking', 's_present', 's_absent', 's_leave', 's_child_days', 'active_classes'];
const SCHOOLS = JSON.parse(fs.readFileSync(path.join(__dirname, 'schools_map.json'), 'utf8'));

let state = { rows: [], as_of: null, attendance: [], attendance_window: null, fico: [], trends: [], last_attempt: null, last_error: null, refreshing: false };

function log(...a) { console.log(new Date().toISOString(), ...a); }

function pktStamp(d = new Date()) {
  const p = new Date(d.getTime() + 5 * 3600 * 1000);
  const pad = (n) => String(n).padStart(2, '0');
  return `${p.getUTCFullYear()}-${pad(p.getUTCMonth() + 1)}-${pad(p.getUTCDate())} ${pad(p.getUTCHours())}:${pad(p.getUTCMinutes())} PKT`;
}

// The data service answers either plain JSON or a server-sent-events stream.
async function readRpc(res) {
  const text = await res.text();
  if ((res.headers.get('content-type') || '').includes('text/event-stream')) {
    const datas = text.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim());
    for (let i = datas.length - 1; i >= 0; i--) {
      try { const j = JSON.parse(datas[i]); if (j.result || j.error) return j; } catch { /* keep looking */ }
    }
    throw new Error('no JSON-RPC result in event stream');
  }
  return JSON.parse(text);
}

async function executeQuery(sql, question = 'daily refresh: STEPS supervisor remarks dashboard, teacher-level') {
  const headers = {
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    'X-Taleemabad-User': MCP_USER,
    'X-Taleemabad-Surface': 'railway-dashboard',
  };
  if (MCP_TOKEN) headers.Authorization = `Bearer ${MCP_TOKEN}`;
  const body = {
    jsonrpc: '2.0', id: Date.now(), method: 'tools/call',
    params: {
      name: 'execute_query',
      arguments: {
        sql,
        question,
        rule_version: RULE_VERSION,
        asked_by: MCP_USER,
        surface: 'railway-dashboard',
      },
    },
  };
  const res = await fetch(MCP_URL, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(180000) });
  if (!res.ok) throw new Error(`data service HTTP ${res.status}`);
  const rpc = await readRpc(res);
  if (rpc.error) throw new Error(`data service error: ${rpc.error.message || JSON.stringify(rpc.error)}`);
  const content = rpc.result && rpc.result.content && rpc.result.content[0];
  if (!content || content.type !== 'text') throw new Error('unexpected tool result shape');
  if (rpc.result.isError) throw new Error(`query failed: ${content.text.slice(0, 300)}`);
  let out = JSON.parse(content.text);
  if (typeof out.result === 'string') out = JSON.parse(out.result);
  if (out.status !== 'ok') throw new Error(`query status ${out.status}: ${JSON.stringify(out).slice(0, 300)}`);
  return out;
}

// Each school row packs its teachers as "tid|name|flags|date|scores|comment" joined by "~".
function expand(result) {
  if (result.truncated) throw new Error('result truncated');
  const rows = result.rows || [];
  if (rows.length < 80) throw new Error(`only ${rows.length} schools returned`);
  const asOf = pktStamp();
  const out = [];
  for (const r of rows) {
    const s = SCHOOLS[r.emis];
    if (!s) throw new Error(`unknown EMIS ${r.emis}`);
    const parts = r.t.split('~');
    if (parts.length !== Number(r.n)) throw new Error(`count mismatch at EMIS ${r.emis}`);
    for (const t of parts) {
      const p = t.split('|');
      if (p.length !== 6) throw new Error(`bad teacher record at EMIS ${r.emis}`);
      const [tid, nm, fl, d, scs, cm] = p;
      if (scs.length !== 0 && scs.length !== 5) throw new Error(`bad scores at EMIS ${r.emis}`);
      const sc = scs.split('').concat(['', '', '', '', '']).slice(0, 5);
      const avg = scs ? (scs.split('').reduce((a, b) => a + Number(b), 0) / 5).toFixed(1) : '';
      out.push({
        teacher_key: `${r.emis}-${tid}`, emis: r.emis, region: s.region, school: s.school,
        teacher: nm || '(no name)', has_remark: fl.includes('R') ? 'Yes' : 'No', remark_date: d,
        s1: sc[0], s2: sc[1], s3: sc[2], s4: sc[3], s5: sc[4], avg_score: avg, comment: cm.trim(), as_of: asOf,
      });
    }
  }
  if (new Set(out.map((o) => o.teacher_key)).size !== out.length) throw new Error('duplicate teacher keys');
  return { rows: out, as_of: asOf };
}

// The 30-day window the attendance query uses, in PKT, for labelling the page.
function attendanceWindow() {
  const day = (offset) => pktStamp(new Date(Date.now() - offset * 86400000)).slice(0, 10);
  return { start: day(29), end: day(0) };
}

async function refreshAttendance() {
  const result = await executeQuery(ATTENDANCE_SQL, 'daily refresh: STEPS dashboard, teacher and student attendance per school, last 30 days');
  if (result.truncated) throw new Error('attendance result truncated');
  const rows = (result.rows || []).filter((r) => SCHOOLS[r.emis]).map((r) => {
    const o = { emis: r.emis };
    for (const f of ATTENDANCE_FIELDS) o[f] = Number(r[f]) || 0;
    return o;
  });
  if (rows.length < 80) throw new Error(`attendance: only ${rows.length} schools returned`);
  return rows;
}

// Each teacher's own attendance (days the head marked them). Adds t_present/t_absent/t_leave to teacher rows;
// left blank where the school's head marks nobody, so "not marked" stays distinct from "0 absences".
async function addTeacherAttendance(rows, schoolAttendance) {
  const result = await executeQuery(TEACHER_ATTENDANCE_SQL, 'daily refresh: STEPS dashboard, each teacher\'s own attendance, last 30 days');
  if (result.truncated) throw new Error('teacher attendance result truncated');
  const byKey = new Map();
  for (const r of result.rows || []) {
    for (const rec of r.t.split('~')) {
      const p = rec.split(':');
      if (p.length !== 4 || p.some((v) => v.includes('redacted'))) throw new Error('teacher attendance record withheld or malformed');
      byKey.set(`${r.emis}-${p[0]}`, { t_present: Number(p[1]), t_absent: Number(p[2]), t_leave: Number(p[3]) });
    }
  }
  const marking = new Set(schoolAttendance.filter((a) => a.t_days_marked > 0).map((a) => a.emis));
  return rows.map((t) => {
    const a = byKey.get(t.teacher_key);
    if (a) return { ...t, ...a };
    if (marking.has(t.emis)) return { ...t, t_present: 0, t_absent: 0, t_leave: 0 };
    return { ...t, t_present: '', t_absent: '', t_leave: '' };
  });
}

// "grade_3 B (morning)" -> "Grade 3 B"; a non-morning shift is kept, e.g. "Grade 4 A (Evening)".
function prettyClass(label) {
  const m = label.match(/^(.*?)\s*(?:\(([^)]*)\))?$/);
  let base = (m[1] || '').replace(/_/g, ' ').replace(/\s+/g, ' ').trim();
  base = base.charAt(0).toUpperCase() + base.slice(1);
  const shift = (m[2] || '').trim();
  return shift && shift.toLowerCase() !== 'morning' ? `${base} (${shift.charAt(0).toUpperCase()}${shift.slice(1)})` : base;
}

// Unmarked class labels per school and each marking teacher's 30-day register totals (approved by the data team).
async function addClassRegisters(rows, attendance) {
  const result = await executeQuery(CLASS_REGISTERS_SQL, 'daily refresh: STEPS dashboard, unmarked classes and teacher register totals, last 30 days');
  if (result.truncated) throw new Error('class registers result truncated');
  const bySchool = new Map();
  const byTeacher = new Map();
  for (const r of result.rows || []) {
    const labels = r.unmarked_class_labels || '';
    const teachers = r.teacher_register_totals || '';
    if (labels.includes('redacted') || teachers.includes('redacted')) throw new Error('class register data withheld by the data service');
    bySchool.set(r.emis, labels ? labels.split(', ').map(prettyClass) : []);
    if (!teachers) continue;
    for (const rec of teachers.split('~')) {
      const p = rec.split(':');
      if (p.length !== 8) throw new Error('malformed teacher register record');
      byTeacher.set(`${r.emis}-${p[0]}`, { reg_days: Number(p[2]), reg_classes: Number(p[3]), reg_present: Number(p[4]),
        reg_absent: Number(p[5]), reg_leave: Number(p[6]), reg_child_days: Number(p[7]) });
    }
  }
  const newAttendance = attendance.map((a) => ({ ...a, unmarked_classes: bySchool.get(a.emis) || [] }));
  const zero = { reg_days: 0, reg_classes: 0, reg_present: 0, reg_absent: 0, reg_leave: 0, reg_child_days: 0 };
  const newRows = rows.map((t) => ({ ...t, ...(byTeacher.get(t.teacher_key) || zero) }));
  return { rows: newRows, attendance: newAttendance, marking: byTeacher.size };
}

// FICO section scores (DC and HITL kept apart): per school with raw sums for exact pooling, and per teacher.
async function addFicoScores(rows) {
  const result = await executeQuery(FICO_SQL, 'daily refresh: STEPS dashboard, FICO subject knowledge / teaching practices / student engagement, since 2026-09-08');
  if (result.truncated) throw new Error('FICO result truncated');
  const num = (v) => (v === null || v === undefined || v === '' ? null : Number(v));
  const schools = [];
  const byTeacher = new Map();
  for (const r of result.rows || []) {
    if (!SCHOOLS[r.emis]) continue;
    const s = { emis: r.emis, observe2_excluded: Number(r.hitl_observe2_visits_excluded) || 0,
      mixed_scale: (Number(r.dc_max_distinct_scales) || 0) > 1 || (Number(r.hitl_max_distinct_scales) || 0) > 1 };
    for (const src of ['dc', 'hitl']) {
      s[`${src}_sessions`] = Number(r[`${src}_sessions`]) || 0;
      s[`${src}_teachers`] = Number(r[`${src}_teachers_observed`]) || 0;
      for (const d of FICO_DOMAINS) {
        s[`${src}_${d}`] = num(r[`${src}_${d}_pct`]);
        s[`${src}_${d}_score`] = num(r[`${src}_${d}_score_sum`]) || 0;
        s[`${src}_${d}_max`] = num(r[`${src}_${d}_max_sum`]) || 0;
      }
    }
    schools.push(s);
    const packed = r.teacher_fico_scores || '';
    if (packed.includes('redacted')) throw new Error('FICO teacher scores withheld by the data service');
    for (const rec of packed ? packed.split('~') : []) {
      const p = rec.split(':');
      if (p.length !== 7) throw new Error('malformed FICO teacher record');
      const key = `${r.emis}-${p[0]}`, src = p[1].toLowerCase();
      const o = byTeacher.get(key) || {};
      o[`${src}_sessions`] = Number(p[2]);
      FICO_DOMAINS.forEach((d, i) => { o[`${src}_${d}`] = p[3 + i] === '' ? '' : Number(p[3 + i]); });
      byTeacher.set(key, o);
    }
  }
  if (schools.length < 80) throw new Error(`FICO: only ${schools.length} schools returned`);
  const blank = {};
  for (const src of ['dc', 'hitl']) { blank[`${src}_sessions`] = 0; FICO_DOMAINS.forEach((d) => { blank[`${src}_${d}`] = ''; }); }
  return { rows: rows.map((t) => ({ ...t, ...blank, ...(byTeacher.get(t.teacher_key) || {}) })), fico: schools };
}

// Each teacher's Digital Coach lessons all time and the day of the last one (dc_all, dc_last; 0 / '' if none).
async function addDcLessons(rows) {
  const result = await executeQuery(DC_LESSONS_SQL, 'daily refresh: STEPS dashboard, Digital Coach lessons per teacher, all time');
  if (result.truncated) throw new Error('DC lessons result truncated');
  const byKey = new Map();
  for (const r of result.rows || []) {
    const packed = r.teacher_dc_lessons || '';
    if (packed.includes('redacted')) throw new Error('DC lessons withheld by the data service');
    for (const rec of packed ? packed.split('~') : []) {
      const p = rec.split(':');
      if (p.length !== 3) throw new Error('malformed DC lessons record');
      byKey.set(`${r.emis}-${p[0]}`, { dc_all: Number(p[1]), dc_last: p[2] });
    }
  }
  return rows.map((t) => ({ ...t, ...(byKey.get(t.teacher_key) || { dc_all: 0, dc_last: '' }) }));
}

// Weekly series per region for the Analytics tab: lessons, visits, DC section scores, remarks, attendance.
async function fetchTrends() {
  const result = await executeQuery(TRENDS_SQL, 'daily refresh: STEPS dashboard analytics, weekly trends per region');
  if (result.truncated) throw new Error('trends result truncated');
  const rows = (result.rows || []).map((r) => {
    const o = { week: String(r.week), region: String(r.region) };
    for (const [k, v] of Object.entries(r)) if (k !== 'week' && k !== 'region') o[k] = v == null ? null : Number(v);
    return o;
  });
  if (!rows.length || rows.some((r) => r.week.includes('redacted'))) throw new Error('trends withheld or empty');
  return rows;
}

async function refresh(reason) {
  if (state.refreshing) return;
  state.refreshing = true;
  state.last_attempt = new Date().toISOString();
  log(`refresh start (${reason})`);
  try {
    if (!MCP_USER) throw new Error('TALEEMABAD_USER is not set');
    if (!MCP_URL) throw new Error('MCP_URL is not set');
    // Build the whole refresh off to the side and swap it in once, so readers never see half-merged rows.
    const prev = new Map(state.rows.map((t) => [t.teacher_key, t]));
    const carry = (rows, fields) => rows.map((t) => {
      const o = prev.get(t.teacher_key);
      if (!o) return t;
      const c = { ...t };
      for (const f of fields) if (f in o) c[f] = o[f];
      return c;
    });
    const ATT_FIELDS = ['t_present', 't_absent', 't_leave', 'reg_days', 'reg_classes', 'reg_present', 'reg_absent', 'reg_leave', 'reg_child_days'];
    const FICO_FIELDS = ['dc', 'hitl'].flatMap((s) => [`${s}_sessions`, ...FICO_DOMAINS.map((d) => `${s}_${d}`)]);
    const next = { attendance: state.attendance, attendance_window: state.attendance_window, fico: state.fico, last_error: null };
    const { rows: baseRows, as_of } = expand(await executeQuery(SQL));
    let rows = baseRows;
    log(`refresh ok: ${rows.length} teachers, ${rows.filter((r) => r.has_remark === 'Yes').length} with remark`);
    try {
      const attendance = await refreshAttendance();
      let r2 = await addTeacherAttendance(rows, attendance);
      const reg = await addClassRegisters(r2, attendance);
      rows = reg.rows;
      Object.assign(next, { attendance: reg.attendance, attendance_window: attendanceWindow() });
      log(`attendance ok: ${attendance.length} schools, ${reg.marking} teachers marking registers, ${reg.attendance.reduce((n, a) => n + a.unmarked_classes.length, 0)} classes not marked`);
    } catch (e) {
      rows = carry(rows, ATT_FIELDS);
      next.last_error = `attendance: ${e.message || e}`;
      log(`attendance refresh failed, keeping previous attendance: ${next.last_error}`);
    }
    try {
      const f = await addFicoScores(rows);
      rows = f.rows;
      next.fico = f.fico;
      log(`FICO ok: ${f.fico.reduce((n, s) => n + s.dc_sessions, 0)} DC sessions, ${f.fico.reduce((n, s) => n + s.hitl_sessions, 0)} HITL sessions`);
    } catch (e) {
      rows = carry(rows, FICO_FIELDS);
      next.last_error = `observations: ${e.message || e}`;
      log(`FICO refresh failed, keeping previous scores: ${next.last_error}`);
    }
    try {
      rows = await addDcLessons(rows);
      log(`DC lessons ok: ${rows.filter((t) => t.dc_all > 0).length} teachers have recorded at least one`);
    } catch (e) {
      rows = carry(rows, ['dc_all', 'dc_last']);
      next.last_error = `DC lessons: ${e.message || e}`;
      log(`DC lessons refresh failed, keeping previous counts: ${next.last_error}`);
    }
    try {
      next.trends = await fetchTrends();
      log(`trends ok: ${next.trends.length} region-weeks`);
    } catch (e) {
      next.trends = state.trends;
      next.last_error = `trends: ${e.message || e}`;
      log(`trends refresh failed, keeping previous trends: ${next.last_error}`);
    }
    state = { ...state, ...next, rows, as_of };
    fs.mkdirSync(DATA_DIR, { recursive: true });
    const payload = { rows: state.rows, as_of: state.as_of, attendance: state.attendance,
      attendance_window: state.attendance_window, fico: state.fico, trends: state.trends };
    fs.writeFileSync(CACHE_FILE, JSON.stringify(payload));
    if (db.enabled()) {
      try {
        await db.saveRefresh(payload, pktStamp().slice(0, 10));
        log('saved snapshot to Postgres');
      } catch (e) {
        log(`Postgres save failed (dashboard unaffected): ${e.message || e}`);
      }
    }
  } catch (e) {
    state.last_error = String(e.message || e);
    log(`refresh failed, keeping previous data: ${state.last_error}`);
    setTimeout(() => refresh('retry'), 30 * 60 * 1000);
  } finally {
    state.refreshing = false;
  }
}

function msUntilNextRun() {
  const now = new Date();
  let best = Infinity;
  for (const t of REFRESH_TIMES_PKT) {
    const next = new Date(now);
    next.setUTCHours(t.h - 5, t.m, 0, 0); // PKT is UTC+5; negative hours roll back a day
    while (next <= now) next.setUTCDate(next.getUTCDate() + 1);
    best = Math.min(best, next - now);
  }
  return best;
}

function scheduleDaily() {
  const ms = msUntilNextRun();
  log(`next scheduled refresh in ${Math.round(ms / 60000)} min`);
  setTimeout(async () => { await refresh('scheduled'); scheduleDaily(); }, ms);
}

const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.png': 'image/png', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.json': 'application/json' };

function send(res, code, body, type, extra = {}) {
  res.writeHead(code, { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff', ...extra });
  res.end(body);
}

// Admin actions (locking quarters) use the same secret as a manual refresh.
const isAdmin = (req) => !!REFRESH_TOKEN && req.headers['x-refresh-token'] === REFRESH_TOKEN;
function readBody(req) {
  return new Promise((resolve, reject) => {
    let b = ''; req.on('data', (c) => { b += c; if (b.length > 1e4) reject(new Error('body too large')); });
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch (e) { reject(e); } });
  });
}
const csvCell = (v) => { const s = v === null || v === undefined ? '' : String(v); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };

async function handleHistory(req, res, url) {
  const json = (code, obj) => send(res, code, JSON.stringify(obj), 'application/json', { 'Cache-Control': 'no-store' });
  if (!db.enabled()) return json(503, { error: 'history storage is not configured' });
  const p = url.pathname;
  if (req.method === 'GET' && p === '/api/history/summary') return json(200, { rows: await db.historySummary() });
  if (req.method === 'GET' && p === '/api/history/teacher') return json(200, await db.teacherHistory(url.searchParams.get('key') || ''));
  if (req.method === 'GET' && p === '/api/history/movers') {
    const back = Math.min(Math.max(Number(url.searchParams.get('days')) || 7, 1), 365);
    return json(200, { rows: await db.movers(back) });
  }
  if (req.method === 'GET' && p === '/api/quarters') return json(200, { rows: await db.listQuarters() });
  const m = p.match(/^\/api\/quarters\/([^/]+)\.csv$/);
  if (req.method === 'GET' && m) {
    const label = decodeURIComponent(m[1]);
    const rows = await db.quarterRows(label);
    if (!rows.length) return send(res, 404, 'not found', 'text/plain');
    const cols = Object.keys(rows[0]);
    const body = '﻿' + [cols.join(','), ...rows.map((r) => cols.map((c) => csvCell(r[c])).join(','))].join('\r\n');
    return send(res, 200, body, 'text/csv; charset=utf-8', { 'Content-Disposition': `attachment; filename="STEPS-${label.replace(/[^A-Za-z0-9_-]+/g, '-')}.csv"` });
  }
  if (req.method === 'POST' && p === '/api/quarters/lock') {
    if (!isAdmin(req)) return json(403, { error: 'Wrong admin key' });
    const body = await readBody(req);
    const label = String(body.label || '').trim().slice(0, 40);
    if (!/^[A-Za-z0-9][A-Za-z0-9 ._-]*$/.test(label)) return json(400, { error: 'Use a label like "2026-27 Q2" (letters, numbers, spaces, - . _)' });
    try { return json(200, await db.lockQuarter(label, String(body.note || '').slice(0, 200))); }
    catch (e) { return json(409, { error: /duplicate key/.test(String(e.message)) ? `"${label}" is already locked` : String(e.message) }); }
  }
  const d = p.match(/^\/api\/quarters\/([^/]+)$/);
  if (req.method === 'DELETE' && d) {
    if (!isAdmin(req)) return json(403, { error: 'Wrong admin key' });
    return json(200, { deleted: await db.deleteQuarter(decodeURIComponent(d[1])) });
  }
  return json(404, { error: 'not found' });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (req.method === 'GET' && url.pathname === '/api/teachers') {
    return send(res, 200, JSON.stringify({ as_of: state.as_of, rows: state.rows,
      attendance: state.attendance, attendance_window: state.attendance_window, fico: state.fico, trends: state.trends, last_attempt: state.last_attempt,
      last_error: state.last_error, refreshing: state.refreshing,
      schedule_pkt: REFRESH_TIMES_PKT.map((t) => `${String(t.h).padStart(2, '0')}:${String(t.m).padStart(2, '0')}`) }),
      'application/json', { 'Cache-Control': 'no-store' });
  }
  if (url.pathname.startsWith('/api/history') || url.pathname.startsWith('/api/quarters')) {
    return handleHistory(req, res, url).catch((e) => { log(`history API error: ${e.message || e}`); send(res, 500, JSON.stringify({ error: 'server error' }), 'application/json'); });
  }
  if (req.method === 'GET' && url.pathname === '/healthz') {
    return send(res, 200, JSON.stringify({ ok: true, teachers: state.rows.length, as_of: state.as_of, last_error: state.last_error }), 'application/json');
  }
  if (req.method === 'POST' && url.pathname === '/api/refresh') {
    if (!REFRESH_TOKEN || req.headers['x-refresh-token'] !== REFRESH_TOKEN) return send(res, 403, 'forbidden', 'text/plain');
    refresh('manual');
    return send(res, 202, 'refresh started', 'text/plain');
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'method not allowed', 'text/plain');
  const rel = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname).replace(/^\/+/, '');
  const file = path.normalize(path.join(PUBLIC_DIR, rel));
  if (!file.startsWith(PUBLIC_DIR)) return send(res, 404, 'not found', 'text/plain');
  fs.readFile(file, (err, buf) => {
    if (err) return send(res, 404, 'not found', 'text/plain');
    const ext = path.extname(file);
    send(res, 200, buf, TYPES[ext] || 'application/octet-stream',
      // Page and scripts change with each deploy, so browsers must revalidate them; fonts and images rarely change.
      { 'Cache-Control': ['.html', '.js', '.css', '.json'].includes(ext) ? 'no-cache' : 'public, max-age=604800' });
  });
});

try {
  const cached = JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8'));
  state = { ...state, rows: cached.rows, as_of: cached.as_of,
    attendance: cached.attendance || [], attendance_window: cached.attendance_window || null, fico: cached.fico || [], trends: cached.trends || [] };
  log(`loaded cached data from ${cached.as_of}`);
} catch { /* first boot: no cache yet */ }

(async () => {
  try {
    if (await db.init()) {
      log('Postgres connected');
      if (!state.rows.length) {
        const c = await db.loadCache();
        if (c && c.rows) {
          state = { ...state, rows: c.rows, as_of: c.as_of, attendance: c.attendance || [], attendance_window: c.attendance_window || null,
            fico: c.fico || [], trends: c.trends || [] };
          log(`loaded cached data from Postgres (${c.as_of})`);
        }
      }
    } else log('DATABASE_URL not set: history features off');
  } catch (e) {
    log(`Postgres unavailable, continuing without history: ${e.message || e}`);
  }
  server.listen(PORT, () => {
    log(`listening on ${PORT}`);
    refresh('startup');
    scheduleDaily();
  });
})();
