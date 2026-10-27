-- Weekly trends per region for the 86 STEPS dashboard schools, weeks starting Monday 2026-08-24 (PKT) to today.
-- Reuses the governed pieces already in this app: §1e teachers and account merges (teacher-headcount.md),
-- FICO sessions as in fico_scores.sql (DC and HITL apart; scores only from 2026-09-08, FICO v3; /observe2
-- excluded), teacher_attendance_marked and student_attendance_marked/_rate (attendance rules). Counts and
-- sums only. Supervisor remarks have no governed rule yet: counted by submitted_at, provisional.
WITH targets AS (
  SELECT emis FROM UNNEST(['203','204','205','206','227','211','209','208','210','212','215','218','216','217','222','295','219','220','221','225','228','229','226','231','230','249','300','236','234','235','237','240','241','242','243','244','245','246','247','248',
  '412','413','439','415','430','421','433','435','428','417','437','466','418','423','419','441','420','424','425','426','427','429','431','432','434','436','438','440','460','461','462','464','465','467','472','468','469','470','471','473','474','475','476','477','478','479']) AS emis
),
sp AS (
  SELECT school_id, LOGICAL_OR(COALESCE(is_programme_school, FALSE)) AS is_programme_school
  FROM `taleemabad_governance.school_programme` GROUP BY school_id
),
sch AS (
  SELECT s.id AS school_id, IF(s.region = 'B.K', 'Barakahu', s.region) AS region
  FROM `Niete_Rumi_db.schools` s
  JOIN targets t ON CAST(s.emis AS STRING) = t.emis
  JOIN sp ON sp.school_id = s.id AND sp.is_programme_school
  WHERE COALESCE(s.region, '') != 'Durbeen'
),
ict_teachers AS (                                               -- teacher-headcount.md 1e
  SELECT u.id AS teacher_id, u.school_id, sch.region
  FROM `Niete_Rumi_db.users` u
  JOIN sch ON sch.school_id = u.school_id
  WHERE u.role = 'teacher' AND u.deleted_at IS NULL AND u.is_test_user IS NOT TRUE
),
ict_account_merges AS (
  SELECT a.retired_id, s.id AS survivor_id
  FROM (
    SELECT JSON_VALUE(detail, '$.retired_user_id') AS retired_id,
           RIGHT(REGEXP_REPLACE(JSON_VALUE(detail, '$.to_phone'), r'\D', ''), 10) AS to_p10,
           ROW_NUMBER() OVER (PARTITION BY JSON_VALUE(detail, '$.retired_user_id')
                              ORDER BY SAFE_CAST(created_at AS TIMESTAMP) DESC) AS rn
    FROM `Niete_Rumi_db.leader_roster_audit`
    WHERE action = 'edit_phone' AND JSON_VALUE(detail, '$.retired_user_id') IS NOT NULL
  ) a
  JOIN `Niete_Rumi_db.users` s
    ON RIGHT(REGEXP_REPLACE(s.phone_number, r'\D', ''), 10) = a.to_p10 AND s.deleted_at IS NULL
  WHERE a.rn = 1 AND s.id != a.retired_id
),
weeks AS (
  SELECT w AS week_start, r AS region
  FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2026-08-24', CURRENT_DATE('Asia/Karachi'), INTERVAL 1 WEEK)) w
  CROSS JOIN UNNEST(['Urban-I', 'Barakahu']) r
),
-- ---- coaching sessions (same filters as fico_scores.sql)
sess AS (
  SELECT cs.id, t.region,
         DATE_TRUNC(DATE(SAFE_CAST(cs.created_at AS TIMESTAMP), 'Asia/Karachi'), WEEK(MONDAY)) AS week_start,
         DATE(SAFE_CAST(cs.created_at AS TIMESTAMP), 'Asia/Karachi') AS d,
         IF(cs.observation_type = 'leader_observation', 'HITL', 'DC') AS source,
         SAFE.PARSE_JSON(cs.analysis_data) AS j
  FROM `Niete_Rumi_db.coaching_sessions` cs
  LEFT JOIN ict_account_merges m ON m.retired_id = cs.user_id
  JOIN ict_teachers t ON t.teacher_id = COALESCE(m.survivor_id, cs.user_id)
  LEFT JOIN `Niete_Rumi_db.users` obs ON obs.id = cs.observer_user_id
  WHERE SAFE_CAST(cs.created_at AS TIMESTAMP) >= TIMESTAMP('2026-08-24', 'Asia/Karachi')
    AND cs.analysis_data IS NOT NULL
    AND JSON_QUERY(cs.analysis_data, '$.scores') IS NOT NULL
    AND ((cs.observation_type IS NULL AND cs.status != 'test_cleanup')
         OR (cs.observation_type = 'leader_observation'
             AND cs.status NOT IN ('cancelled', 'abandoned', 'failed', 'test_cleanup')))
    AND (cs.observer_user_id IS NULL OR cs.observer_user_id != cs.user_id)
    AND obs.is_test_user IS NOT TRUE
    AND JSON_VALUE(cs.analysis_data, '$.observe2.rubric') IS NULL
),
sess_w AS (
  SELECT region, week_start,
         COUNT(DISTINCT IF(source = 'DC', id, NULL))   AS dc_lessons,
         COUNT(DISTINCT IF(source = 'HITL', id, NULL)) AS hitl_visits
  FROM sess GROUP BY 1, 2
),
dom AS (                                                        -- DC section scores, FICO v3 only
  SELECT s.region, s.week_start, k AS domain,
         SAFE_CAST(JSON_VALUE(s.j.domains[k].domain_score) AS FLOAT64) AS score,
         SAFE_CAST(JSON_VALUE(s.j.domains[k].domain_max)   AS FLOAT64) AS mx
  FROM sess s, UNNEST(JSON_KEYS(s.j.domains, 1)) AS k
  WHERE s.source = 'DC' AND s.d >= DATE '2026-09-08'
    AND k IN ('teacher_subject_knowledge', 'high_leverage_practices', 'student_engagement')
),
dom_w AS (
  SELECT region, week_start,
    SUM(IF(domain = 'teacher_subject_knowledge', score, NULL)) AS dc_tsk_score, SUM(IF(domain = 'teacher_subject_knowledge', mx, NULL)) AS dc_tsk_max,
    SUM(IF(domain = 'high_leverage_practices', score, NULL))   AS dc_hlp_score, SUM(IF(domain = 'high_leverage_practices', mx, NULL))   AS dc_hlp_max,
    SUM(IF(domain = 'student_engagement', score, NULL))        AS dc_se_score,  SUM(IF(domain = 'student_engagement', mx, NULL))        AS dc_se_max
  FROM dom WHERE mx > 0 AND score IS NOT NULL GROUP BY 1, 2
),
-- ---- supervisor remarks submitted (provisional: no governed rule)
rem_w AS (
  SELECT sch.region, DATE_TRUNC(DATE(SAFE_CAST(r.submitted_at AS TIMESTAMP), 'Asia/Karachi'), WEEK(MONDAY)) AS week_start,
         COUNT(DISTINCT r.id) AS remarks_submitted
  FROM `Niete_Rumi_db.supervisor_remarks` r JOIN sch ON sch.school_id = r.school_id
  WHERE r.submitted_at IS NOT NULL
  GROUP BY 1, 2
),
-- ---- teacher attendance (teacher_attendance_marked)
tdays AS (
  SELECT DISTINCT r.id, r.status, t.region, DATE_TRUNC(SAFE_CAST(r.date AS DATE), WEEK(MONDAY)) AS week_start
  FROM `Niete_Rumi_db.teacher_attendance_records` r
  LEFT JOIN ict_account_merges m ON m.retired_id = r.teacher_id
  JOIN ict_teachers t ON t.teacher_id = COALESCE(m.survivor_id, r.teacher_id)
  LEFT JOIN `Niete_Rumi_db.users` mk ON mk.id = r.marked_by_user_id
  WHERE mk.is_test_user IS NOT TRUE AND SAFE_CAST(r.date AS DATE) >= DATE '2026-08-24'
),
t_w AS (
  SELECT region, week_start,
         COUNT(DISTINCT IF(status = 'present', id, NULL)) AS t_present,
         COUNT(DISTINCT IF(status = 'absent', id, NULL))  AS t_absent,
         COUNT(DISTINCT IF(status = 'leave', id, NULL))   AS t_leave
  FROM tdays GROUP BY 1, 2
),
-- ---- student attendance (student_attendance_marked / _rate): register rollups, counts only
regs AS (
  SELECT DISTINCT a.id, t.region, DATE_TRUNC(SAFE_CAST(a.session_date AS DATE), WEEK(MONDAY)) AS week_start,
         a.present_count, a.total_students
  FROM `Niete_Rumi_db.attendance_sessions` a
  LEFT JOIN ict_account_merges m ON m.retired_id = a.user_id
  JOIN ict_teachers t ON t.teacher_id = COALESCE(m.survivor_id, a.user_id)
  WHERE SAFE_CAST(a.session_date AS DATE) >= DATE '2026-08-24'
),
s_w AS (
  SELECT region, week_start, COUNT(DISTINCT id) AS s_registers,
         SUM(present_count) AS s_present, SUM(total_students) AS s_child_days
  FROM regs GROUP BY 1, 2
)
SELECT FORMAT_DATE('%Y-%m-%d', w.week_start) AS week, w.region,
       COALESCE(sw.dc_lessons, 0) AS dc_lessons, COALESCE(sw.hitl_visits, 0) AS hitl_visits,
       dw.dc_tsk_score, dw.dc_tsk_max, dw.dc_hlp_score, dw.dc_hlp_max, dw.dc_se_score, dw.dc_se_max,
       COALESCE(rw.remarks_submitted, 0) AS remarks_submitted,
       COALESCE(tw.t_present, 0) AS t_present, COALESCE(tw.t_absent, 0) AS t_absent, COALESCE(tw.t_leave, 0) AS t_leave,
       COALESCE(s.s_registers, 0) AS s_registers, COALESCE(s.s_present, 0) AS s_present, COALESCE(s.s_child_days, 0) AS s_child_days
FROM weeks w
LEFT JOIN sess_w sw ON sw.region = w.region AND sw.week_start = w.week_start
LEFT JOIN dom_w dw  ON dw.region = w.region AND dw.week_start = w.week_start
LEFT JOIN rem_w rw  ON rw.region = w.region AND rw.week_start = w.week_start
LEFT JOIN t_w tw    ON tw.region = w.region AND tw.week_start = w.week_start
LEFT JOIN s_w s     ON s.region = w.region AND s.week_start = w.week_start
ORDER BY w.week_start, w.region
