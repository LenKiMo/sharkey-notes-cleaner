-- 补索引：修复「删一条 note 要全表扫描子表」的问题（PostgreSQL 需要按子表 FK 列找子行）
--
-- ⚠️ CREATE INDEX CONCURRENTLY 不能跑在事务块里：
--    psql 直接 `\i 本文件` 或 `psql -f 本文件` 都可以；**不要**加 `-1`/`--single-transaction`。
--    用容器跑：docker exec -i <db容器> sh -c 'psql -U $POSTGRES_USER -d $POSTGRES_DB' < 02-add-missing-indexes.sql
-- 三条都是**新增**索引（不删不改），对应用透明；将来上游 migration 不会与它们冲突。
-- 先跑 01-check-missing-fk-indexes.sql 确认你的实例确实缺这些索引，再执行本文件。

-- 实测（一个 310 万行 note 的实例，删除单价）：
--   latest_note.note_id   缺索引 → 13 ms/行
--   note_edit.replyId     缺索引 → 72 ms/行
--   note_edit.renoteId    缺索引 → 55 ms/行
--   合计 140 ms/行；补索引后 7.4 ms/行（约 19 倍）

CREATE INDEX CONCURRENTLY IF NOT EXISTS "IDX_latest_note_note_id" ON latest_note ("note_id");
CREATE INDEX CONCURRENTLY IF NOT EXISTS "IDX_note_edit_replyId"   ON note_edit   ("replyId");
CREATE INDEX CONCURRENTLY IF NOT EXISTS "IDX_note_edit_renoteId"  ON note_edit   ("renoteId");

-- 批量删除期间建议临时收紧 autovacuum（300 万行的表用默认 scale_factor=0.2 要攒 60 万死元组才触发）：
--   ALTER TABLE note SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_cost_limit = 800);
-- 注意 autovacuum_naptime 是全局 GUC，写进 per-table 选项会让整条 ALTER 失败回滚。
-- 跑完可保留（对大表更合理）或 ALTER TABLE note RESET (autovacuum_vacuum_scale_factor, autovacuum_vacuum_cost_limit);
