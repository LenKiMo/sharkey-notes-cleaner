#!/bin/bash
# 一次性维护入口：VACUUM FULL note
#   停清理定时器 → 等清理容器退出 → 全表重写 → 起定时器 → 通报结果
# 由 systemd oneshot（sharkey-notes-cleaner-vacuum.service）在低峰窗口调用。
#
#   DRY=1 ./vacuum-maintenance.sh      # 只打印将要做什么，不动任何东西
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/sharkey-notes-cleaner}"
CLEANER_TIMER="sharkey-notes-cleaner.timer"
LOG="${LOG:-/var/log/sharkey-cleaner/vacuum-maintenance.log}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
DRY="${DRY:-0}"
DB_CONTAINER="${DB_CONTAINER:-sharkey_db}"

mkdir -p "$(dirname "$LOG")"
say() { echo "[$(date '+%F %T %Z')] $*" | tee -a "$LOG"; }
q() { docker exec "$DB_CONTAINER" sh -c "psql -q -tA -U \$POSTGRES_USER -d \$POSTGRES_DB -c \"$1\"" 2>/dev/null; }

if [ "$DRY" = "1" ]; then
  echo "DRY 模式：将要执行的动作"
  echo "  1) systemctl stop  $CLEANER_TIMER"
  echo "  2) 等清理容器（sharkey-notes-cleaner*）退出，最多 10 分钟"
  echo "  3) $INSTALL_DIR/tools/vacuum-full.sh   # VACUUM (FULL, ANALYZE) note"
  echo "  4) systemctl start $CLEANER_TIMER"
  echo "  5) 通过 $NOTIFY_CMD 通报前后体积与耗时"
  echo "当前: note=$(q "select pg_size_pretty(pg_total_relation_size('note'))") heap=$(q "select pg_size_pretty(pg_table_size('note'))") idx=$(q "select pg_size_pretty(pg_indexes_size('note'))") db=$(q "select pg_size_pretty(pg_database_size(current_database()))")"
  echo "在跑的清理容器: $(docker ps --format '{{.Names}}' | grep -c cleaner)"
  exit 0
fi

before=$(q "select pg_size_pretty(pg_total_relation_size('note'))")
say "=== 维护开始 before: note=$before | db=$(q "select pg_size_pretty(pg_database_size(current_database()))") ==="

say "停清理定时器 $CLEANER_TIMER"
systemctl stop "$CLEANER_TIMER" || say "WARN: stop timer 返回非 0（可能本来就没启用）"

for i in $(seq 1 20); do
  n=$(docker ps --format '{{.Names}}' | grep -c cleaner || true)
  [ "$n" -eq 0 ] && break
  say "等清理容器退出（第 $i 次，仍在跑 $n 个）"
  sleep 30
done
still=$(docker ps --format '{{.Names}}' | grep -c cleaner || true)
if [ "$still" -ne 0 ]; then
  say "仍有清理容器在跑，放弃本次维护（避免与清理互相干扰）"
  systemctl start "$CLEANER_TIMER" || true
  [ -x "$NOTIFY_CMD" ] && "$NOTIFY_CMD" "⚠️ VACUUM FULL 维护已跳过：仍有清理容器在跑（$still 个）。下次窗口再试。" || true
  exit 3
fi

t0=$(date +%s)
"$INSTALL_DIR/tools/vacuum-full.sh"
rc=$?
elapsed=$(( $(date +%s) - t0 ))
after=$(q "select pg_size_pretty(pg_total_relation_size('note'))")

say "起清理定时器"
systemctl start "$CLEANER_TIMER" || say "WARN: start timer 失败，请手工 systemctl start $CLEANER_TIMER"

say "=== 维护结束 rc=$rc 耗时 ${elapsed}s：note $before → $after | db=$(q "select pg_size_pretty(pg_database_size(current_database()))") ==="

if [ -x "$NOTIFY_CMD" ]; then
  if [ "$rc" -eq 0 ]; then
    "$NOTIFY_CMD" "✅ VACUUM FULL 完成（${elapsed}s）
note 表：$before → $after
整库：$(q "select pg_size_pretty(pg_database_size(current_database()))")
磁盘：$(df -h / | awk 'NR==2{print $4" 可用"}')
日志：$LOG" || true
  else
    "$NOTIFY_CMD" "❌ VACUUM FULL 失败 rc=$rc（耗时 ${elapsed}s），见 $LOG" || true
  fi
fi
exit "$rc"
