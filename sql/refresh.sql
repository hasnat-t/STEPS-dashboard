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
  FROM `Niete_Rumi_db.schools` s JOIN targets t ON CAST(s.emis AS STRING) = t.emis
  JOIN sp ON sp.school_id = s.id AND sp.is_programme_school
),
ict_teachers AS (
  SELECT u.id AS teacher_id, u.name, u.school_id
  FROM `Niete_Rumi_db.users` u
  JOIN sch ON sch.school_id = u.school_id
  WHERE u.role = 'teacher' AND u.deleted_at IS NULL AND u.is_test_user IS NOT TRUE
),
sc AS (
  SELECT remark_id, STRING_AGG(CAST(score AS STRING), '' ORDER BY indicator_ordinal) AS scores
  FROM `Niete_Rumi_db.supervisor_remark_scores` GROUP BY remark_id
),
rm AS (
  SELECT r.teacher_id, r.school_id, r.comment_text, SUBSTR(r.submitted_at, 1, 10) AS d, sc.scores
  FROM `Niete_Rumi_db.supervisor_remarks` r LEFT JOIN sc ON sc.remark_id = r.id
  WHERE r.school_id IN (SELECT school_id FROM sch)
),
j AS (
  SELECT sch.emis, SUBSTR(COALESCE(t.teacher_id, rm.teacher_id), 1, 8) AS tid,
         REPLACE(REPLACE(COALESCE(t.name, u2.name, ''), '|', ' '), '~', ' ') AS nm,
         IF(t.teacher_id IS NOT NULL, 'H', 'X') AS hc,
         IF(rm.teacher_id IS NOT NULL, 'R', '') AS rk,
         COALESCE(rm.d, '') AS d, COALESCE(rm.scores, '') AS scs,
         REPLACE(REPLACE(REPLACE(COALESCE(rm.comment_text, ''), '|', ' '), '~', ' '), '\n', ' ') AS cm
  FROM ict_teachers t
  FULL OUTER JOIN rm ON rm.teacher_id = t.teacher_id
  LEFT JOIN `Niete_Rumi_db.users` u2 ON u2.id = rm.teacher_id
  JOIN sch ON sch.school_id = COALESCE(t.school_id, rm.school_id)
)
SELECT emis, COUNT(*) AS n,
       STRING_AGG(CONCAT(tid, '|', nm, '|', hc, rk, '|', d, '|', scs, '|', cm), '~' ORDER BY rk DESC, nm) AS t
FROM j GROUP BY emis ORDER BY SAFE_CAST(emis AS INT64)
