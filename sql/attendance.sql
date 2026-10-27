-- Teacher and student attendance per school, last 30 days (PKT), for the 86 STEPS dashboard schools.
-- Governed definitions (rules v0.39.1): teacher_attendance_marked / teacher_attendance_rate (staff register,
-- present over present+absent, leave apart) and student_attendance_marked / student_attendance_rate
-- (class registers, present over child-days marked, leave counted as not present). Counts only.
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
    AND 'PRIMARY' IN UNNEST(ARRAY(SELECT DISTINCT TRIM(UPPER(x)) FROM UNNEST(JSON_VALUE_ARRAY(u.teacher_level)) x))  -- STEPS scope: primary teachers (teacher-levels.md 1b)
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
tdays AS (                                                      -- teacher_attendance_marked
  SELECT DISTINCT r.id, r.status, SAFE_CAST(r.date AS DATE) AS d, t.teacher_id, t.school_id,
         COALESCE(mm.survivor_id, r.marked_by_user_id) AS principal_id
  FROM `Niete_Rumi_db.teacher_attendance_records` r
  CROSS JOIN win
  LEFT JOIN ict_account_merges m ON m.retired_id = r.teacher_id
  JOIN ict_teachers t ON t.teacher_id = COALESCE(m.survivor_id, r.teacher_id)
  LEFT JOIN ict_account_merges mm ON mm.retired_id = r.marked_by_user_id
  LEFT JOIN `Niete_Rumi_db.users` mk ON mk.id = r.marked_by_user_id
  WHERE mk.is_test_user IS NOT TRUE
    AND SAFE_CAST(r.date AS DATE) BETWEEN win.d0 AND win.d1
),
t_school AS (
  SELECT school_id,
         COUNT(DISTINCT id)                               AS t_days_marked,
         COUNT(DISTINCT IF(status = 'present', id, NULL)) AS t_present,
         COUNT(DISTINCT IF(status = 'absent', id, NULL))  AS t_absent,
         COUNT(DISTINCT IF(status = 'leave', id, NULL))   AS t_leave,
         COUNT(DISTINCT teacher_id)                       AS t_teachers_marked,
         COUNT(DISTINCT d)                                AS t_dates_marked
  FROM tdays GROUP BY school_id
),
registers AS (                                                  -- student_attendance_marked
  SELECT DISTINCT a.id, t.teacher_id, t.school_id, sl.class_id, SAFE_CAST(a.session_date AS DATE) AS d,
         a.present_count, a.absent_count, COALESCE(a.leave_count, 0) AS leave_count, a.total_students
  FROM `Niete_Rumi_db.attendance_sessions` a
  CROSS JOIN win
  LEFT JOIN ict_account_merges m ON m.retired_id = a.user_id
  JOIN ict_teachers t ON t.teacher_id = COALESCE(m.survivor_id, a.user_id)
  LEFT JOIN `Niete_Rumi_db.student_lists` sl ON sl.id = a.list_id
  LEFT JOIN `Niete_Rumi_db.classes` rc ON rc.id = sl.class_id
  WHERE SAFE_CAST(a.session_date AS DATE) BETWEEN win.d0 AND win.d1
    AND (rc.id IS NULL OR LOWER(TRIM(rc.grade_code)) IN ('early_years', 'grade_1', 'grade_2', 'grade_3', 'grade_4', 'grade_5'))   -- primary classes
),
s_regs AS (
  SELECT DISTINCT id, school_id, present_count, absent_count, leave_count, total_students FROM registers
),
s_school AS (
  SELECT r.school_id,
         COUNT(DISTINCT r.id)         AS s_class_days,
         COUNT(DISTINCT r.class_id)   AS s_classes_marked,
         COUNT(DISTINCT r.teacher_id) AS s_teachers_marking,
         ANY_VALUE(x.present)  AS s_present, ANY_VALUE(x.absent) AS s_absent,
         ANY_VALUE(x.on_leave) AS s_leave,   ANY_VALUE(x.child_days) AS s_child_days
  FROM registers r
  JOIN (SELECT school_id, SUM(present_count) AS present, SUM(absent_count) AS absent,
               SUM(leave_count) AS on_leave, SUM(total_students) AS child_days
        FROM s_regs GROUP BY school_id) x ON x.school_id = r.school_id
  GROUP BY r.school_id
),
classes AS (
  SELECT c.school_id, COUNT(DISTINCT c.id) AS active_classes
  FROM `Niete_Rumi_db.classes` c JOIN sch ON sch.school_id = c.school_id
  WHERE c.is_active AND LOWER(TRIM(c.grade_code)) IN ('early_years', 'grade_1', 'grade_2', 'grade_3', 'grade_4', 'grade_5') GROUP BY c.school_id
)
SELECT sch.emis,
       COALESCE(t.t_days_marked, 0) AS t_days_marked, COALESCE(t.t_present, 0) AS t_present,
       COALESCE(t.t_absent, 0) AS t_absent, COALESCE(t.t_leave, 0) AS t_leave,
       COALESCE(t.t_teachers_marked, 0) AS t_teachers_marked, COALESCE(t.t_dates_marked, 0) AS t_dates_marked,
       COALESCE(s.s_class_days, 0) AS s_class_days, COALESCE(s.s_classes_marked, 0) AS s_classes_marked,
       COALESCE(s.s_teachers_marking, 0) AS s_teachers_marking,
       COALESCE(s.s_present, 0) AS s_present, COALESCE(s.s_absent, 0) AS s_absent,
       COALESCE(s.s_leave, 0) AS s_leave, COALESCE(s.s_child_days, 0) AS s_child_days,
       COALESCE(c.active_classes, 0) AS active_classes
FROM sch
LEFT JOIN t_school t ON t.school_id = sch.school_id
LEFT JOIN s_school s ON s.school_id = sch.school_id
LEFT JOIN classes c ON c.school_id = sch.school_id
ORDER BY SAFE_CAST(sch.emis AS INT64)
