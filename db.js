// Postgres storage for the STEPS dashboard: a startup cache, one STEPS snapshot per teacher per day,
// and locked quarter results that never change once taken. Everything is optional: without DATABASE_URL
// the server runs as before (memory + cache file).
const { Pool } = require('pg');

let pool = null;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS app_cache (
  id smallint PRIMARY KEY,
  payload jsonb NOT NULL,
  saved_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS daily_snapshot (
  day date NOT NULL,
  teacher_key text NOT NULL,
  emis text, region text, school text, teacher text,
  steps numeric, complete boolean, parts smallint, weight smallint,
  sk numeric, tp numeric, se numeric, ta numeric, sa numeric, sr numeric,
  dc_lessons int, has_remark boolean, as_of text,
  PRIMARY KEY (day, teacher_key)
);
CREATE INDEX IF NOT EXISTS daily_snapshot_teacher ON daily_snapshot (teacher_key, day);
CREATE TABLE IF NOT EXISTS quarter_lock (
  label text PRIMARY KEY,
  snapshot_day date NOT NULL,
  teachers int NOT NULL,
  note text,
  locked_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS quarter_result (
  label text NOT NULL REFERENCES quarter_lock(label) ON DELETE CASCADE,
  teacher_key text NOT NULL,
  emis text, region text, school text, teacher text,
  steps numeric, complete boolean, parts smallint, weight smallint,
  sk numeric, tp numeric, se numeric, ta numeric, sa numeric, sr numeric,
  dc_lessons int, has_remark boolean, as_of text,
  PRIMARY KEY (label, teacher_key)
);`;

const COLS = ['teacher_key', 'emis', 'region', 'school', 'teacher', 'steps', 'complete', 'parts', 'weight',
  'sk', 'tp', 'se', 'ta', 'sa', 'sr', 'dc_lessons', 'has_remark', 'as_of'];

// Same rules as stepsFor() on the page: classroom parts from the Digital Coach (since 8 Sep), presence over
// the last 30 days, remark = mean of 5 indicators / 4. No classroom score -> no STEPS number.
const PARTS = [['sk', 30], ['tp', 25], ['se', 25], ['ta', 7], ['sa', 3], ['sr', 10]];
function computeSteps(t) {
  const n = (x) => (x === '' || x === null || x === undefined ? null : Number(x));
  const dc = Number(t.dc_sessions || 0);
  const tP = n(t.t_present), tA = n(t.t_absent);
  const kids = Number(t.reg_child_days || 0);
  const rem = t.has_remark === 'Yes' && t.s1 !== '' ? [1, 2, 3, 4, 5].reduce((a, i) => a + Number(t[`s${i}`]), 0) / 5 : null;
  const v = {
    sk: dc && n(t.dc_tsk) !== null ? n(t.dc_tsk) / 100 : null,
    tp: dc && n(t.dc_hlp) !== null ? n(t.dc_hlp) / 100 : null,
    se: dc && n(t.dc_se) !== null ? n(t.dc_se) / 100 : null,
    ta: tP !== null && tP + tA > 0 ? tP / (tP + tA) : null,
    sa: kids ? Number(t.reg_present) / kids : null,
    sr: rem !== null ? rem / 4 : null,
  };
  let w = 0, acc = 0;
  for (const [k, wt] of PARTS) if (v[k] !== null) { w += wt; acc += wt * v[k]; }
  const groups = [v.sk !== null, v.tp !== null, v.se !== null, v.ta !== null || v.sa !== null, v.sr !== null].filter(Boolean).length;
  const hasClassroom = v.sk !== null && v.tp !== null && v.se !== null;
  return { ...v, steps: hasClassroom && w ? acc / w : null, complete: w === 100, parts: groups, weight: w };
}

function toRecord(t, asOf) {
  const s = computeSteps(t);
  return { teacher_key: t.teacher_key, emis: t.emis, region: t.region, school: t.school, teacher: t.teacher,
    steps: s.steps, complete: s.complete, parts: s.parts, weight: s.weight, sk: s.sk, tp: s.tp, se: s.se,
    ta: s.ta, sa: s.sa, sr: s.sr, dc_lessons: Number(t.dc_sessions || 0), has_remark: t.has_remark === 'Yes', as_of: asOf };
}

async function init() {
  if (!process.env.DATABASE_URL) return false;
  pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 4 });
  await pool.query(SCHEMA);
  return true;
}
const enabled = () => pool !== null;

async function loadCache() {
  if (!pool) return null;
  const r = await pool.query('SELECT payload FROM app_cache WHERE id = 1');
  return r.rows[0] ? r.rows[0].payload : null;
}

// Save the full payload (for instant startup) and today's PKT snapshot (replacing any earlier one today).
async function saveRefresh(payload, pktDay) {
  if (!pool) return;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`INSERT INTO app_cache (id, payload, saved_at) VALUES (1, $1, now())
      ON CONFLICT (id) DO UPDATE SET payload = EXCLUDED.payload, saved_at = now()`, [payload]);
    await client.query('DELETE FROM daily_snapshot WHERE day = $1', [pktDay]);
    const recs = payload.rows.map((t) => toRecord(t, payload.as_of));
    const arrays = COLS.map((c) => recs.map((r) => r[c]));
    await client.query(`INSERT INTO daily_snapshot (day, ${COLS.join(', ')})
      SELECT $1::date, * FROM UNNEST($2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::numeric[], $8::boolean[],
        $9::smallint[], $10::smallint[], $11::numeric[], $12::numeric[], $13::numeric[], $14::numeric[], $15::numeric[],
        $16::numeric[], $17::int[], $18::boolean[], $19::text[])`, [pktDay, ...arrays]);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
}

// Per day and region: teachers, scored, complete, averages, level counts and part averages.
async function historySummary() {
  const r = await pool.query(`
    SELECT to_char(day, 'YYYY-MM-DD') AS day, region,
      COUNT(*)::int AS teachers,
      COUNT(steps)::int AS scored,
      COUNT(*) FILTER (WHERE complete AND steps IS NOT NULL)::int AS complete,
      AVG(steps)::float AS avg_steps,
      AVG(steps) FILTER (WHERE complete)::float AS avg_steps_complete,
      COUNT(*) FILTER (WHERE steps >= 0.8)::int AS exemplary,
      COUNT(*) FILTER (WHERE steps >= 0.7 AND steps < 0.8)::int AS proficient,
      COUNT(*) FILTER (WHERE steps >= 0.6 AND steps < 0.7)::int AS developing,
      COUNT(*) FILTER (WHERE steps < 0.6)::int AS support,
      COUNT(*) FILTER (WHERE steps IS NULL)::int AS incomplete,
      AVG(sk)::float AS sk, AVG(tp)::float AS tp, AVG(se)::float AS se, AVG(ta)::float AS ta, AVG(sa)::float AS sa, AVG(sr)::float AS sr,
      COUNT(*) FILTER (WHERE has_remark)::int AS with_remark
    FROM daily_snapshot GROUP BY day, region ORDER BY day, region`);
  return r.rows;
}

async function teacherHistory(key) {
  const days = await pool.query(`SELECT to_char(day, 'YYYY-MM-DD') AS day, steps::float, complete, parts, sk::float, tp::float,
      se::float, ta::float, sa::float, sr::float, dc_lessons FROM daily_snapshot WHERE teacher_key = $1 ORDER BY day`, [key]);
  const q = await pool.query(`SELECT r.label, to_char(l.snapshot_day, 'YYYY-MM-DD') AS snapshot_day, r.steps::float, r.complete, r.parts
      FROM quarter_result r JOIN quarter_lock l USING (label) WHERE r.teacher_key = $1 ORDER BY l.snapshot_day`, [key]);
  return { days: days.rows, quarters: q.rows };
}

// Biggest STEPS changes between the latest day and the latest day at least `back` days earlier.
async function movers(back) {
  const r = await pool.query(`
    WITH latest AS (SELECT MAX(day) AS d FROM daily_snapshot),
    earlier AS (SELECT MAX(day) AS d FROM daily_snapshot, latest WHERE day <= latest.d - $1::int)
    SELECT to_char((SELECT d FROM earlier), 'YYYY-MM-DD') AS from_day, to_char((SELECT d FROM latest), 'YYYY-MM-DD') AS to_day,
      a.teacher_key, a.teacher, a.school, a.emis, a.region, b.steps::float AS before, a.steps::float AS after,
      (a.steps - b.steps)::float AS change
    FROM daily_snapshot a JOIN daily_snapshot b ON b.teacher_key = a.teacher_key
    WHERE a.day = (SELECT d FROM latest) AND b.day = (SELECT d FROM earlier)
      AND a.steps IS NOT NULL AND b.steps IS NOT NULL`, [back]);
  return r.rows;
}

async function listQuarters() {
  const r = await pool.query(`
    SELECT l.label, to_char(l.snapshot_day, 'YYYY-MM-DD') AS snapshot_day, l.teachers, l.note,
      to_char(l.locked_at AT TIME ZONE 'Asia/Karachi', 'YYYY-MM-DD HH24:MI') AS locked_at_pkt,
      r.region, COUNT(*)::int AS region_teachers, COUNT(r.steps)::int AS scored,
      COUNT(*) FILTER (WHERE r.complete AND r.steps IS NOT NULL)::int AS complete,
      AVG(r.steps)::float AS avg_steps, AVG(r.steps) FILTER (WHERE r.complete)::float AS avg_steps_complete,
      COUNT(*) FILTER (WHERE r.steps >= 0.8)::int AS exemplary,
      COUNT(*) FILTER (WHERE r.steps >= 0.7 AND r.steps < 0.8)::int AS proficient,
      COUNT(*) FILTER (WHERE r.steps >= 0.6 AND r.steps < 0.7)::int AS developing,
      COUNT(*) FILTER (WHERE r.steps < 0.6)::int AS support
    FROM quarter_lock l JOIN quarter_result r USING (label)
    GROUP BY l.label, l.snapshot_day, l.teachers, l.note, l.locked_at, r.region
    ORDER BY l.snapshot_day DESC, r.region`);
  return r.rows;
}

// Copy the latest daily snapshot into quarter_result under `label`. Refuses an existing label.
async function lockQuarter(label, note) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const d = await client.query('SELECT MAX(day) AS d FROM daily_snapshot');
    if (!d.rows[0].d) throw new Error('No snapshot yet to lock');
    const n = await client.query('SELECT COUNT(*)::int AS n FROM daily_snapshot WHERE day = $1', [d.rows[0].d]);
    await client.query('INSERT INTO quarter_lock (label, snapshot_day, teachers, note) VALUES ($1, $2, $3, $4)',
      [label, d.rows[0].d, n.rows[0].n, note || null]);
    await client.query(`INSERT INTO quarter_result (label, ${COLS.join(', ')})
      SELECT $1, ${COLS.join(', ')} FROM daily_snapshot WHERE day = $2`, [label, d.rows[0].d]);
    await client.query('COMMIT');
    return { label, snapshot_day: d.rows[0].d, teachers: n.rows[0].n };
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
}

async function deleteQuarter(label) {
  const r = await pool.query('DELETE FROM quarter_lock WHERE label = $1', [label]);
  return r.rowCount;
}

async function quarterRows(label) {
  const r = await pool.query(`SELECT ${COLS.join(', ')} FROM quarter_result WHERE label = $1 ORDER BY region, emis, teacher`, [label]);
  return r.rows;
}

module.exports = { init, enabled, loadCache, saveRefresh, historySummary, teacherHistory, movers, listQuarters,
  lockQuarter, deleteQuarter, quarterRows, computeSteps };
