#!/bin/bash
# VACUUM FULL note：把 note 表与索引重写，真正把空间还给操作系统。
#
# ⚠️ 会持有 ACCESS EXCLUSIVE 锁：期间对该表的读写都会阻塞（站点会出现一段不可用/超时）。
#    需要约「表+索引」量级的额外磁盘空间；会话内必须 statement_timeout=0，且不能放在事务块里。
#
# 实测参考（310 万行 note / 3.79GB 的实例，删到 59.5 万行后）：
#   before: table=3792MB heap=1673MB idx=2119MB db=9608MB → after: ≈1GB（预计回收 ~2.8GB）
#   普通 VACUUM 只把空间标记为可复用，df 不会降；只有 FULL / REINDEX 才还给 OS。
#
# 用法（低峰窗口，root）：
#   systemctl stop sharkey-notes-cleaner.timer      # 先停定时器，避免与清理互相干扰
#   /opt/sharkey-notes-cleaner/vacuum-full.sh
#   systemctl start sharkey-notes-cleaner.timer     # 跑完再开
set -uo pipefail
DB_CONTAINER="${DB_CONTAINER:-sharkey_db}"
LOG="${LOG:-/var/log/sharkey-cleaner/vacuum-full.log}"
mkdir -p "$(dirname "$LOG")"
q() { docker exec "$DB_CONTAINER" sh -c "psql -q -tA -U \$POSTGRES_USER -d \$POSTGRES_DB -c \"$1\""; }

{
  echo "=== START $(date '+%F %T %Z') ==="
  echo "清理器容器在跑？ $(docker ps --format '{{.Names}}' | grep -c cleaner)（应为 0）"
  echo "before: note=$(q "select pg_size_pretty(pg_total_relation_size('note'))") heap=$(q "select pg_size_pretty(pg_table_size('note'))") idx=$(q "select pg_size_pretty(pg_indexes_size('note'))") db=$(q "select pg_size_pretty(pg_database_size(current_database()))")"
  t0=$(date +%s)
  q "SET statement_timeout=0; VACUUM (FULL, ANALYZE, VERBOSE) note;"
  rc=$?
  echo "elapsed=$(( $(date +%s) - t0 ))s"
  echo "after : note=$(q "select pg_size_pretty(pg_total_relation_size('note'))") heap=$(q "select pg_size_pretty(pg_table_size('note'))") idx=$(q "select pg_size_pretty(pg_indexes_size('note'))") db=$(q "select pg_size_pretty(pg_database_size(current_database()))")"
  echo "=== DONE rc=$rc $(date '+%F %T %Z') ==="
  df -h / | tail -1
} >> "$LOG" 2>&1
tail -20 "$LOG"
exit "${rc:-0}"
