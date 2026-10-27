-- Class registers per school and per teacher, since 8 Sep 2026 (PKT), for the 86 STEPS dashboard schools.
-- Governed definition (rules v0.39.1): student_attendance_marked / student_attendance_rate. Counts only:
-- never a child, never a single register.
-- Approved by the data team (Hasnat Tariq, 2026-10-27): unmarked class labels (grade + section) and each
-- marking teacher's register totals may be served. Column names follow the serving policy's own
-- categories so it serves them: class labels are a class dimension, teacher_* is staff-scoped
-- (serving_policy.py _SAFE_DIMENSION_RE / _STAFF_SCOPED_RE).
-- Packed teacher_register_totals record: teacher_id8:registers:days:classes:present:absent:on_leave:child_days
WITH targets AS (
  SELECT emis FROM UNNEST(['203','204','205','206','227','211','209','208','210','212','215','218','216','217','222','295','219','220','221','225','228','229','226','231','230','249','300','236','234','235','237','240','241','242','243','244','245','246','247','248',
  '412','413','439','415','430','421','433','435','428','417','437','466','418','423','419','441','420','424','425','426','427','429','431','432','434','436','438','440','460','461','462','464','465','467','472','468','469','470','471','473','474','475','476','477','478','479']) AS emis
),
win AS (
  SELECT DATE '2026-09-08' AS d0, CURRENT_DATE('Asia/Karachi') AS d1   -- STEPS period: same start as the classroom parts (FICO v3)
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
per_teacher AS (                                                -- totals per marking teacher over the STEPS period
  SELECT school_id, teacher_id,
         COUNT(DISTINCT id) AS registers, COUNT(DISTINCT d) AS days, COUNT(DISTINCT class_id) AS classes,
         SUM(present_count) AS present, SUM(absent_count) AS absent, SUM(leave_count) AS on_leave,
         SUM(total_students) AS child_days
  FROM (SELECT DISTINCT id, teacher_id, school_id, class_id, d, present_count, absent_count, leave_count, total_students
        FROM registers)
  GROUP BY school_id, teacher_id
),
marked_classes AS (SELECT DISTINCT class_id FROM registers WHERE class_id IS NOT NULL),
cls AS (
  SELECT c.school_id, c.id,
         TRIM(CONCAT(COALESCE(c.grade_code, '?'), ' ', COALESCE(c.section, ''),
                     IF(c.shift_code IS NOT NULL AND c.shift_code != '', CONCAT(' (', c.shift_code, ')'), ''))) AS label,
         mc.class_id IS NOT NULL AS is_marked
  FROM `Niete_Rumi_db.classes` c
  JOIN sch ON sch.school_id = c.school_id
  LEFT JOIN marked_classes mc ON mc.class_id = c.id
  WHERE c.is_active AND LOWER(TRIM(c.grade_code)) IN ('early_years', 'grade_1', 'grade_2', 'grade_3', 'grade_4', 'grade_5')
),
cls_school AS (
  SELECT school_id, COUNT(*) AS active_class_count, COUNTIF(is_marked) AS marked_class_count,
         STRING_AGG(IF(is_marked, NULL, label), ', ' ORDER BY label) AS unmarked_class_labels
  FROM cls GROUP BY school_id
),
teacher_school AS (
  SELECT school_id,
         STRING_AGG(CONCAT(SUBSTR(teacher_id, 1, 8), ':', CAST(registers AS STRING), ':', CAST(days AS STRING), ':',
                           CAST(classes AS STRING), ':', CAST(present AS STRING), ':', CAST(absent AS STRING), ':',
                           CAST(on_leave AS STRING), ':', CAST(child_days AS STRING)), '~' ORDER BY teacher_id)
           AS teacher_register_totals
  FROM per_teacher GROUP BY school_id
)
SELECT sch.emis,
       COALESCE(c.active_class_count, 0) AS active_class_count,
       COALESCE(c.marked_class_count, 0) AS marked_class_count,
       c.unmarked_class_labels,
       t.teacher_register_totals
FROM sch
LEFT JOIN cls_school c ON c.school_id = sch.school_id
LEFT JOIN teacher_school t ON t.school_id = sch.school_id
ORDER BY SAFE_CAST(sch.emis AS INT64)
