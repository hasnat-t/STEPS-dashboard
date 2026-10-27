-- Each teacher's own attendance, last 30 days (PKT), for the 86 STEPS dashboard schools, packed one row per
-- school (the data service returns at most 100 rows). Governed definition (rules v0.39.1):
-- teacher_attendance_marked / teacher_absence_by_teacher - the days the school head marked this teacher.
-- Students' attendance is deliberately NOT joined here: the data service withholds teacher identifiers from any
-- result that touches the minors' tables (attendance_sessions, student_lists), so class attendance stays school-level.
-- Packed record per teacher: tid8:t_present:t_absent:t_leave
WITH targets AS (
  SELECT emis FROM UNNEST(['203','204','205','206','227','211','209','208','210','212','215','218','216','217','222','295','219','220','221','225','228','229','226','231','230','249','300','236','234','235','237','240','241','242','243','244','245','246','247','248',
  '412','413','439','415','430','421','433','435','428','417','437','466','418','423','419','441','420','424','425','426','427','429','431','432','434','436','438','440','460','461','462','464','465','467','472','468','469','470','471','473','474','475','476','477','478','479']) AS emis
),
win AS (
  SELECT DATE_SUB(CURRENT_DATE('Asia/Karachi'), INTERVAL 29 DAY) AS d0, CURRENT_DATE('Asia/Karachi') AS d1
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
  SELECT u.id AS teacher_id, u.school_id
  FROM `Niete_Rumi_db.users` u
  JOIN sch ON sch.school_id = u.school_id
  WHERE u.role = 'teacher' AND u.deleted_at IS NULL
    AND u.is_test_user IS NOT TRUE
),
ict_account_merges AS (                                         -- a merged-away account's rows go to the survivor
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
tdays AS (
  SELECT DISTINCT r.id, r.status, t.teacher_id
  FROM `Niete_Rumi_db.teacher_attendance_records` r
  CROSS JOIN win
  LEFT JOIN ict_account_merges m ON m.retired_id = r.teacher_id
  JOIN ict_teachers t ON t.teacher_id = COALESCE(m.survivor_id, r.teacher_id)
  LEFT JOIN `Niete_Rumi_db.users` mk ON mk.id = r.marked_by_user_id
  WHERE mk.is_test_user IS NOT TRUE
    AND SAFE_CAST(r.date AS DATE) BETWEEN win.d0 AND win.d1
),
t_teacher AS (
  SELECT teacher_id,
         COUNT(DISTINCT IF(status = 'present', id, NULL)) AS t_present,
         COUNT(DISTINCT IF(status = 'absent', id, NULL))  AS t_absent,
         COUNT(DISTINCT IF(status = 'leave', id, NULL))   AS t_leave
  FROM tdays GROUP BY teacher_id
),
per_teacher AS (
  SELECT sch.emis, t.teacher_id,
         CONCAT(SUBSTR(t.teacher_id, 1, 8), ':',
                CAST(COALESCE(tt.t_present, 0) AS STRING), ':', CAST(COALESCE(tt.t_absent, 0) AS STRING), ':',
                CAST(COALESCE(tt.t_leave, 0) AS STRING)) AS rec
  FROM ict_teachers t
  JOIN sch ON sch.school_id = t.school_id
  JOIN t_teacher tt ON tt.teacher_id = t.teacher_id
)
SELECT emis, COUNT(*) AS n, STRING_AGG(rec, '~' ORDER BY teacher_id) AS t
FROM per_teacher GROUP BY emis ORDER BY SAFE_CAST(emis AS INT64)
