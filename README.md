# STEPS Teacher Evaluation Dashboard

A live dashboard for NIETE's **STEPS** teacher evaluation in two ICT sectors, **Urban-I** and **Barakahu** (86 schools).

**Scope: primary teachers only** (about 840): teachers whose Rumi `teacher_level` includes PRIMARY, so primary-only teachers and those who teach both primary and middle/high. Teachers who teach only middle or high classes, and teachers with no level recorded, are left out. Class counts and student attendance use primary classes only (early years to grade 5). The filter sits in the `ict_teachers` step of every query in `sql/`.

It shows each teacher's STEPS score and the five parts behind it, per region, per school and per teacher, and refreshes itself from the Taleemabad data service twice a day.

## What STEPS measures

| Part | Weight | Source |
|---|---|---|
| Subject knowledge | 30% | Digital Coach FICO score, section F (from 8 Sep 2026, FICO v3) |
| Teaching practices | 25% | Digital Coach FICO score, section C |
| Student engagement | 25% | Digital Coach FICO score, section D |
| Presence | 10% | Teacher attendance marked by the head (7%) and student attendance from class registers (3%), since 8 Sep (same period as the classroom parts) |
| Supervisor remark | 10% | The head's quarterly rating on 5 indicators (1–4), averaged ÷ 4 |

Performance levels: **Exemplary** 80+, **Proficient** 70–79.9, **Developing** 60–69.9, **Needs support** below 60. A teacher with no Digital Coach classroom score since 8 Sep is shown as **Incomplete** (no STEPS number).

## Tabs

Overview · Analytics (charts and weekly trends) · Progress (STEPS over time, biggest changes, locked quarter results) · Supervisor remarks · Classroom observations · Presence · All schools · Teachers (with a scorecard per teacher). Every section can be saved as a PNG with **Download image**.

## How it works

```
Browser ──► server.js (Railway) ──► Taleemabad data service (MCP over HTTP) ──► BigQuery (Niete_Rumi_db)
```

- `server.js` is a small Node server with no dependencies. At startup and at the times in `REFRESH_TIMES_PKT` it runs the queries in `sql/` through the data service's `execute_query` tool, joins the results per teacher, and keeps them in memory (plus a cache file in `DATA_DIR`).
- The page asks `/api/teachers` for the data; visitors never query BigQuery themselves.
- If a refresh fails, the last good data stays up and the refresh is retried after 30 minutes.
- With `DATABASE_URL` set (Railway Postgres), `db.js` also saves one STEPS snapshot per teacher per day (`daily_snapshot`), keeps the latest payload for instant startup (`app_cache`), and stores **locked quarter results** that never change (`quarter_lock`, `quarter_result`). Without it the dashboard still works, minus the Progress tab.

### History API

| Endpoint | |
|---|---|
| `GET /api/history/summary` | Per day and region: averages, level counts, part averages |
| `GET /api/history/teacher?key=` | One teacher's daily STEPS and locked quarter results |
| `GET /api/history/movers?days=7` | Biggest STEPS changes vs N days earlier |
| `GET /api/quarters` · `GET /api/quarters/<label>.csv` | Locked quarters and their full results as CSV |
| `POST /api/quarters/lock` `{label, note}` · `DELETE /api/quarters/<label>` | Admin only: header `x-refresh-token` |

### Queries (`sql/`)

| File | What it returns |
|---|---|
| `refresh.sql` | Teachers per school (governed ICT headcount) with their supervisor remark, scores and comment |
| `attendance.sql` | Teacher and student attendance per school, since 8 Sep (same period as the classroom parts) |
| `teacher_attendance.sql` | Each teacher's own attendance, since 8 Sep (same period as the classroom parts) |
| `class_registers.sql` | Classes with no register marked, and each teacher's register totals, since 8 Sep (same period as the classroom parts) |
| `fico_scores.sql` | FICO section scores per school and teacher, Digital Coach and coach visits kept apart |
| `dc_lessons.sql` | Each teacher's Digital Coach lessons, all time, and the last one |
| `trends.sql` | Weekly series per region for the Analytics tab |

Results are packed one row per school because the data service returns at most 100 rows. Children's data is only ever used as counts.

## Settings (environment variables)

| Variable | Required | Meaning |
|---|---|---|
| `MCP_URL` | yes | URL of the Taleemabad data service's MCP endpoint |
| `TALEEMABAD_USER` | yes | Email the data service logs each query under |
| `REFRESH_TOKEN` | no | Admin key: `POST /api/refresh` and locking/deleting quarters (header `x-refresh-token`) |
| `REFRESH_TIMES_PKT` | no | Refresh times, e.g. `07:13,14:13` (default) |
| `DATABASE_URL` | no | Postgres connection string; on Railway `${{Postgres.DATABASE_URL}}` (private network) |
| `TALEEMABAD_API_TOKEN` | no | Bearer token, only if the data service turns on strict auth |
| `DATA_DIR` | no | Where the cache file is written (default `./data`) |
| `PORT` | no | Set by the host |

## Run locally

```bash
MCP_URL=... TALEEMABAD_USER=you@example.org node server.js
# open http://localhost:3000
```

## Change the page

Edit `page/page-fragment.html`, then rebuild `public/index.html`:

```bash
python build_page.py page/page-fragment.html
```

## Deploy (Railway)

```bash
railway up --detach
```

Health check: `GET /healthz`.
