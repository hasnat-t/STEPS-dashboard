-- FICO section scores per school and per teacher (subject knowledge, teaching practices, student engagement,
-- lesson-plan fidelity) for the 86 STEPS dashboard schools. Governed (rules v0.39.1): fico-scores-rules.md §2/§2c,
-- coaching-query-rules.md §1 (DC and HITL never pooled), teacher-headcount.md §1e. FICO v3 only: from
-- 2026-09-08 PKT (start must stay fixed) through today. /observe2 (fico17) visits excluded and counted.
-- Written by the data-analyst agent 2026-10-27; only the upper date bound was made relative.
WITH sp AS (
  SELECT school_id, LOGICAL_OR(COALESCE(is_programme_school, FALSE)) AS is_programme_school
  FROM `taleemabad_governance.school_programme` GROUP BY school_id
),
target_schools AS (                                   -- the 86 dashboard schools, programme list only, Durbeen out
  SELECT s.id AS school_id, TRIM(CAST(s.emis AS STRING)) AS emis
  FROM `Niete_Rumi_db.schools` s
  JOIN sp ON sp.school_id = s.id AND sp.is_programme_school
  WHERE COALESCE(s.region, '') != 'Durbeen'
    AND TRIM(CAST(s.emis AS STRING)) IN (
      '203','204','205','206','227','211','209','208','210','212','215','218','216','217','222','295',
      '219','220','221','225','228','229','226','231','230','249','300','236','234','235','237','240',
      '241','242','243','244','245','246','247','248','412','413','439','415','430','421','433','435',
      '428','417','437','466','418','423','419','441','420','424','425','426','427','429','431','432',
      '434','436','438','440','460','461','462','464','465','467','472','468','469','470','471','473',
      '474','475','476','477','478','479')
),
ict_teachers AS (                                     -- teacher-headcount.md 1e, restricted to the 86 schools
  SELECT u.id AS teacher_id, ts.emis
  FROM `Niete_Rumi_db.users` u
  JOIN target_schools ts ON ts.school_id = u.school_id
  WHERE u.role = 'teacher' AND u.deleted_at IS NULL
    AND u.is_test_user IS NOT TRUE                    -- test accounts (data-governance.md)
    AND 'PRIMARY' IN UNNEST(ARRAY(SELECT DISTINCT TRIM(UPPER(x)) FROM UNNEST(JSON_VALUE_ARRAY(u.teacher_level)) x))  -- STEPS scope: primary teachers (teacher-levels.md 1b)
),
ict_account_merges AS (                               -- merged-away account -> surviving account
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
sess_all AS (
  SELECT cs.id AS session_id, t.teacher_id, t.emis,
         IF(cs.observation_type = 'leader_observation', 'HITL', 'DC') AS source,
         cs.has_lesson_plan,
         JSON_VALUE(cs.analysis_data, '$.observe2.rubric') IS NOT NULL AS is_observe2,
         SAFE.PARSE_JSON(cs.analysis_data) AS j
  FROM `Niete_Rumi_db.coaching_sessions` cs
  LEFT JOIN ict_account_merges m ON m.retired_id = cs.user_id
  JOIN ict_teachers t ON t.teacher_id = COALESCE(m.survivor_id, cs.user_id)   -- the TEACHER observed / self-recording
  LEFT JOIN `Niete_Rumi_db.users` obs ON obs.id = cs.observer_user_id          -- the coach (HITL only)
  WHERE SAFE_CAST(cs.created_at AS TIMESTAMP) >= TIMESTAMP('2026-09-08', 'Asia/Karachi')   -- FICO v3 only
    AND SAFE_CAST(cs.created_at AS TIMESTAMP) <  TIMESTAMP(DATE_ADD(CURRENT_DATE('Asia/Karachi'), INTERVAL 1 DAY), 'Asia/Karachi')  -- through today PKT
    AND cs.analysis_data IS NOT NULL
    AND JSON_QUERY(cs.analysis_data, '$.scores') IS NOT NULL
    AND ((cs.observation_type IS NULL AND cs.status != 'test_cleanup')                       -- DC: scores returned
         OR (cs.observation_type = 'leader_observation'
             AND cs.status NOT IN ('cancelled', 'abandoned', 'failed', 'test_cleanup')))      -- HITL: conducted
    AND (cs.observer_user_id IS NULL OR cs.observer_user_id != cs.user_id)                   -- visit names a teacher
    AND obs.is_test_user IS NOT TRUE                                                         -- test observers
),
sess AS (SELECT * FROM sess_all WHERE NOT is_observe2),   -- /observe2 fico17 is another rubric: never pooled
dom AS (
  SELECT s.session_id, s.teacher_id, s.emis, s.source, k AS domain,
         SAFE_CAST(JSON_VALUE(s.j.domains[k].domain_score) AS FLOAT64) AS score,
         SAFE_CAST(JSON_VALUE(s.j.domains[k].domain_max)   AS FLOAT64) AS mx
  FROM sess s, UNNEST(JSON_KEYS(s.j.domains, 1)) AS k                -- read the keys; never hardcode
  WHERE (k != 'lesson_plan_fidelity' OR s.has_lesson_plan IS TRUE)  -- LP fidelity only where a plan was attached
),
dom_ok AS (SELECT * FROM dom WHERE mx > 0 AND score IS NOT NULL),
teacher_rec AS (
  SELECT ts.emis, ts.teacher_id, ts.source, ts.sessions,
         d.tsk, d.hlp, d.se, d.lpf
  FROM (SELECT emis, teacher_id, source, COUNT(DISTINCT session_id) AS sessions
        FROM sess GROUP BY 1, 2, 3) ts
  LEFT JOIN (
    SELECT emis, teacher_id, source,
      SAFE_DIVIDE(SUM(IF(domain = 'teacher_subject_knowledge', score, NULL)), SUM(IF(domain = 'teacher_subject_knowledge', mx, NULL))) AS tsk,
      SAFE_DIVIDE(SUM(IF(domain = 'high_leverage_practices',   score, NULL)), SUM(IF(domain = 'high_leverage_practices',   mx, NULL))) AS hlp,
      SAFE_DIVIDE(SUM(IF(domain = 'student_engagement',        score, NULL)), SUM(IF(domain = 'student_engagement',        mx, NULL))) AS se,
      SAFE_DIVIDE(SUM(IF(domain = 'lesson_plan_fidelity',      score, NULL)), SUM(IF(domain = 'lesson_plan_fidelity',      mx, NULL))) AS lpf
    FROM dom_ok GROUP BY 1, 2, 3
  ) d USING (emis, teacher_id, source)
),
teacher_pack AS (
  SELECT emis,
         STRING_AGG(CONCAT(SUBSTR(teacher_id, 1, 8), ':', source, ':', CAST(sessions AS STRING), ':',
                           IF(tsk IS NULL, '', FORMAT('%.1f', ROUND(100 * tsk, 1))), ':',
                           IF(hlp IS NULL, '', FORMAT('%.1f', ROUND(100 * hlp, 1))), ':',
                           IF(se  IS NULL, '', FORMAT('%.1f', ROUND(100 * se,  1))), ':',
                           IF(lpf IS NULL, '', FORMAT('%.1f', ROUND(100 * lpf, 1)))),
                    '~' ORDER BY teacher_id, source) AS teacher_fico_scores
  FROM teacher_rec GROUP BY emis
),
school_sess AS (
  SELECT emis,
         COUNT(DISTINCT IF(source = 'DC',   session_id, NULL)) AS dc_sessions,
         COUNT(DISTINCT IF(source = 'DC',   teacher_id, NULL)) AS dc_teachers_observed,
         COUNT(DISTINCT IF(source = 'HITL', session_id, NULL)) AS hitl_sessions,
         COUNT(DISTINCT IF(source = 'HITL', teacher_id, NULL)) AS hitl_teachers_observed
  FROM sess GROUP BY emis
),
school_dom AS (
  SELECT emis,
    SUM(IF(source='DC' AND domain='teacher_subject_knowledge', score, NULL)) AS dc_tsk_score_sum,
    SUM(IF(source='DC' AND domain='teacher_subject_knowledge', mx, NULL)) AS dc_tsk_max_sum,
    SUM(IF(source='DC' AND domain='high_leverage_practices', score, NULL)) AS dc_hlp_score_sum,
    SUM(IF(source='DC' AND domain='high_leverage_practices', mx, NULL)) AS dc_hlp_max_sum,
    SUM(IF(source='DC' AND domain='student_engagement', score, NULL)) AS dc_se_score_sum,
    SUM(IF(source='DC' AND domain='student_engagement', mx, NULL)) AS dc_se_max_sum,
    SUM(IF(source='DC' AND domain='lesson_plan_fidelity', score, NULL)) AS dc_lpf_score_sum,
    SUM(IF(source='DC' AND domain='lesson_plan_fidelity', mx, NULL)) AS dc_lpf_max_sum,
    SUM(IF(source='HITL' AND domain='teacher_subject_knowledge', score, NULL)) AS hitl_tsk_score_sum,
    SUM(IF(source='HITL' AND domain='teacher_subject_knowledge', mx, NULL)) AS hitl_tsk_max_sum,
    SUM(IF(source='HITL' AND domain='high_leverage_practices', score, NULL)) AS hitl_hlp_score_sum,
    SUM(IF(source='HITL' AND domain='high_leverage_practices', mx, NULL)) AS hitl_hlp_max_sum,
    SUM(IF(source='HITL' AND domain='student_engagement', score, NULL)) AS hitl_se_score_sum,
    SUM(IF(source='HITL' AND domain='student_engagement', mx, NULL)) AS hitl_se_max_sum,
    SUM(IF(source='HITL' AND domain='lesson_plan_fidelity', score, NULL)) AS hitl_lpf_score_sum,
    SUM(IF(source='HITL' AND domain='lesson_plan_fidelity', mx, NULL)) AS hitl_lpf_max_sum,
    SAFE_DIVIDE(SUM(IF(source='DC'   AND domain='teacher_subject_knowledge', score, NULL)), SUM(IF(source='DC'   AND domain='teacher_subject_knowledge', mx, NULL))) AS dc_tsk,
    SAFE_DIVIDE(SUM(IF(source='DC'   AND domain='high_leverage_practices',   score, NULL)), SUM(IF(source='DC'   AND domain='high_leverage_practices',   mx, NULL))) AS dc_hlp,
    SAFE_DIVIDE(SUM(IF(source='DC'   AND domain='student_engagement',        score, NULL)), SUM(IF(source='DC'   AND domain='student_engagement',        mx, NULL))) AS dc_se,
    SAFE_DIVIDE(SUM(IF(source='DC'   AND domain='lesson_plan_fidelity',      score, NULL)), SUM(IF(source='DC'   AND domain='lesson_plan_fidelity',      mx, NULL))) AS dc_lpf,
    SAFE_DIVIDE(SUM(IF(source='HITL' AND domain='teacher_subject_knowledge', score, NULL)), SUM(IF(source='HITL' AND domain='teacher_subject_knowledge', mx, NULL))) AS hitl_tsk,
    SAFE_DIVIDE(SUM(IF(source='HITL' AND domain='high_leverage_practices',   score, NULL)), SUM(IF(source='HITL' AND domain='high_leverage_practices',   mx, NULL))) AS hitl_hlp,
    SAFE_DIVIDE(SUM(IF(source='HITL' AND domain='student_engagement',        score, NULL)), SUM(IF(source='HITL' AND domain='student_engagement',        mx, NULL))) AS hitl_se,
    SAFE_DIVIDE(SUM(IF(source='HITL' AND domain='lesson_plan_fidelity',      score, NULL)), SUM(IF(source='HITL' AND domain='lesson_plan_fidelity',      mx, NULL))) AS hitl_lpf
  FROM dom_ok GROUP BY emis
),
scales AS (                                           -- >1 = window spans a rubric change; TSK 20/24/28 = one scale
  SELECT emis,
         MAX(IF(source = 'DC',   n, NULL)) AS dc_max_distinct_scales,
         MAX(IF(source = 'HITL', n, NULL)) AS hitl_max_distinct_scales
  FROM (SELECT emis, source, domain,
               COUNT(DISTINCT IF(domain = 'teacher_subject_knowledge' AND mx IN (20, 24, 28), 24, mx)) AS n
        FROM dom_ok
        WHERE domain IN ('teacher_subject_knowledge','high_leverage_practices','student_engagement','lesson_plan_fidelity')
        GROUP BY 1, 2, 3)
  GROUP BY emis
),
observe2 AS (
  SELECT emis, COUNT(DISTINCT session_id) AS hitl_observe2_visits_excluded
  FROM sess_all WHERE is_observe2 GROUP BY emis
),
school_list AS (
  SELECT emis, COUNT(DISTINCT school_id) AS school_rows FROM target_schools GROUP BY emis
),
teachers_at_school AS (
  SELECT emis, COUNT(DISTINCT teacher_id) AS teachers_with_school FROM ict_teachers GROUP BY emis
)
SELECT sl.emis,
       sl.school_rows,
       COALESCE(tas.teachers_with_school, 0)          AS teachers_with_school,
       COALESCE(ss.dc_sessions, 0)                    AS dc_sessions,
       COALESCE(ss.dc_teachers_observed, 0)           AS dc_teachers_observed,
       ROUND(100 * sd.dc_tsk, 1)                      AS dc_tsk_pct,
       ROUND(100 * sd.dc_hlp, 1)                      AS dc_hlp_pct,
       ROUND(100 * sd.dc_se,  1)                      AS dc_se_pct,
       ROUND(100 * sd.dc_lpf, 1)                      AS dc_lpf_pct,
       COALESCE(ss.hitl_sessions, 0)                  AS hitl_sessions,
       COALESCE(ss.hitl_teachers_observed, 0)         AS hitl_teachers_observed,
       ROUND(100 * sd.hitl_tsk, 1)                    AS hitl_tsk_pct,
       ROUND(100 * sd.hitl_hlp, 1)                    AS hitl_hlp_pct,
       ROUND(100 * sd.hitl_se,  1)                    AS hitl_se_pct,
       ROUND(100 * sd.hitl_lpf, 1)                    AS hitl_lpf_pct,
       sc.dc_max_distinct_scales,
       sc.hitl_max_distinct_scales,
       COALESCE(o2.hitl_observe2_visits_excluded, 0)  AS hitl_observe2_visits_excluded,
       tp.teacher_fico_scores,
       sd.dc_tsk_score_sum,
       sd.dc_tsk_max_sum,
       sd.dc_hlp_score_sum,
       sd.dc_hlp_max_sum,
       sd.dc_se_score_sum,
       sd.dc_se_max_sum,
       sd.dc_lpf_score_sum,
       sd.dc_lpf_max_sum,
       sd.hitl_tsk_score_sum,
       sd.hitl_tsk_max_sum,
       sd.hitl_hlp_score_sum,
       sd.hitl_hlp_max_sum,
       sd.hitl_se_score_sum,
       sd.hitl_se_max_sum,
       sd.hitl_lpf_score_sum,
       sd.hitl_lpf_max_sum
FROM school_list sl
LEFT JOIN teachers_at_school tas USING (emis)
LEFT JOIN school_sess ss USING (emis)
LEFT JOIN school_dom sd USING (emis)
LEFT JOIN scales sc USING (emis)
LEFT JOIN observe2 o2 USING (emis)
LEFT JOIN teacher_pack tp USING (emis)
ORDER BY SAFE_CAST(sl.emis AS INT64)
