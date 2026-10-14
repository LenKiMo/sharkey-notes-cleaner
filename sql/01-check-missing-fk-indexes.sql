-- 体检：列出「引用 note 的外键」中**子表 FK 列没有索引**的项
--
-- 为什么重要：PostgreSQL 的 ON DELETE CASCADE 需要按子表的 FK 列查找子行。
-- 若该列没有索引，每删一条 note 都要**全表扫描**该子表 —— 这是删帖慢的常见根因。
-- 实测一例：latest_note.note_id(13ms) + note_edit.replyId(72ms) + note_edit.renoteId(55ms)
-- 缺索引，导致删除单价 140ms/行；补索引后降到 7.4ms/行（19 倍）。
--
-- 用法：docker exec -i <db容器> sh -c 'psql -U $POSTGRES_USER -d $POSTGRES_DB' < 01-check-missing-fk-indexes.sql
--      或直接在 psql 里 \i 本文件。只读，不修改任何东西。

\pset border 2
SELECT
  c.conrelid::regclass::text                                   AS child_table,
  a.attname                                                    AS fk_column,
  pg_size_pretty(pg_total_relation_size(c.conrelid))           AS child_size
FROM pg_constraint c
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
WHERE c.contype = 'f'
  AND c.confrelid = 'note'::regclass
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND (i.indkey::text ~ ('(^| )' || c.conkey[1] || '( |$)'))
  )
ORDER BY pg_total_relation_size(c.conrelid) DESC;

-- 顺带看一眼 note 表本体的规模与索引规模
SELECT
  pg_size_pretty(pg_table_size('note'))                        AS note_heap,
  pg_size_pretty(pg_indexes_size('note'))                      AS note_indexes,
  (SELECT count(*) FROM pg_index i WHERE i.indrelid = 'note'::regclass) AS note_index_count;
