-- Each teacher's Digital Coach lessons, all time and the date of the last one, for the 86 STEPS dashboard schools.
-- Same session filter as fico_scores.sql for DC (scores returned, status != 'test_cleanup'), no date window.
-- Packed one row per school (the data service returns at most 100 rows): teacher_dc_lessons record =
-- teacher_id8:dc_lessons_all_time:last_lesson_day(YYYY-MM-DD, PKT).
WITH targets AS (
  SELECT emis FROM UNNEST(['203','204','205','206','227','211','209','208','210','212','215','218','216','217','222','295','219','220','221','225','228','229','226','231','230','249','300','236','234','235','237','240','241','242','243','244','245','246','247','248',
  '412','413','439','415','430','421','433','435','428','417','437','466','418','423','419','441','420','424','425','426','427','429','431','432','434','436','438','440','460','461','462','464','465','467','472','468','469','470','471','473','474','475','476','477','478','479']) AS emis
),
sp AS (
  SELECT school_id, LOGICAL_OR(COALESCE(is_programme_school, FALSE)) AS is_programme_school
  FROM `taleemabad_governance.school_programme` GROUP BY school_id
),
sch AS (
  SELECT s.id AS school_id, CAST(s.emis AS STRING) AS emis
  FROM `Niete_Rumi_db.schools` s
  JOIN targets t ON CAST(s.emis AS STRING) = t.emis
  JOIN sp ON sp.school_id = s.id AND sp.is_programme_school
  WHERE COALESCE(s.region, '') != 'Durbeen'
),
ict_teachers AS (                                               -- teacher-headcount.md 1e
  SELECT u.id AS teacher_id, sch.emis
  FROM `Niete_Rumi_db.users` u
  JOIN sch ON sch.school_id = u.school_id
  WHERE u.role = 'teacher' AND u.deleted_at IS NULL AND u.is_test_user IS NOT TRUE
    AND 'PRIMARY' IN UNNEST(ARRAY(SELECT DISTINCT TRIM(UPPER(x)) FROM UNNEST(JSON_VALUE_ARRAY(u.teacher_level)) x))  -- STEPS scope: primary teachers (teacher-levels.md 1b)
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
dc AS (
  SELECT t.emis, t.teacher_id, COUNT(DISTINCT cs.id) AS lessons,
         MAX(DATE(SAFE_CAST(cs.created_at AS TIMESTAMP), 'Asia/Karachi')) AS last_day
  FROM `Niete_Rumi_db.coaching_sessions` cs
  LEFT JOIN ict_account_merges m ON m.retired_id = cs.user_id
  JOIN ict_teachers t ON t.teacher_id = COALESCE(m.survivor_id, cs.user_id)
  WHERE cs.observation_type IS NULL AND cs.status != 'test_cleanup'
    AND cs.analysis_data IS NOT NULL AND JSON_QUERY(cs.analysis_data, '$.scores') IS NOT NULL
  GROUP BY 1, 2
)
SELECT emis, STRING_AGG(CONCAT(SUBSTR(teacher_id, 1, 8), ':', CAST(lessons AS STRING), ':', FORMAT_DATE('%Y-%m-%d', last_day)), '~' ORDER BY teacher_id) AS teacher_dc_lessons
FROM dc GROUP BY emis ORDER BY SAFE_CAST(emis AS INT64)
