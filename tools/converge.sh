#!/bin/bash
# 收敛循环：反复跑清理器，直到某一轮「0 删除」为止。
#
# 为什么需要它：删除规则只删「无子节点的叶子」。一条被转帖/被回复的远程帖，
# 必须等它的子节点先被删掉、变成叶子，才会在**下一轮**被删。实测层叠衰减约为
# 150.8k → 60.3k → 32.5k → 19.8k → 13.5k → 9.9k …（每轮约 0.5–0.7 倍），所以
# 单轮跑不到 0，需要循环收敛。稳态运行时每天一轮即可（新到期的帖都是新叶子）。
#
# 用法（在装了本工具的宿主机上，root）：
#   /opt/sharkey-notes-cleaner/tools/converge.sh            # 默认最多 15 轮，每轮 ≤15 分钟
#   MAX_PASSES=8 PER_PASS_MINUTES=30 bash converge.sh
#
# 依赖 /etc/default/sharkey-notes-cleaner（install.sh 会写），且**不要**与 systemd timer 重叠：
#   systemctl stop sharkey-notes-cleaner.timer   # 跑之前先停 timer
set -uo pipefail

ENV_FILE="${ENV_FILE:-/etc/default/sharkey-notes-cleaner}"
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

INSTALL_DIR="${INSTALL_DIR:-/opt/sharkey-notes-cleaner}"
IMAGE="${CLEANER_IMAGE:?CLEANER_IMAGE 未设置（见 $ENV_FILE）}"
NETWORK="${CLEANER_NETWORK:?CLEANER_NETWORK 未设置}"
CONFIG_DIR="${CLEANER_CONFIG_DIR:?CLEANER_CONFIG_DIR 未设置}"
SHARKEY_HOME="${CLEANER_SHARKEY_HOME:-/sharkey}"
STATE_DIR="${CLEANER_STATE_DIR:-/var/lib/sharkey-notes-cleaner}"
LOG_DIR="${LOG_DIR:-/var/log/sharkey-cleaner}"
MAX_PASSES="${MAX_PASSES:-15}"
PER_PASS_MINUTES="${PER_PASS_MINUTES:-15}"
BATCH="${BATCH:-2000}"
SLEEP_MS="${SLEEP_MS:-300}"
EXPIRY_DAYS="${EXPIRY_DAYS:-90}"

mkdir -p "$LOG_DIR" "$STATE_DIR"
total=0
for i in $(seq 1 "$MAX_PASSES"); do
  name="sharkey-notes-cleaner-conv$i"
  docker rm -f "$name" >/dev/null 2>&1
  t0=$(date +%s)
  docker run --name "$name" --network "$NETWORK" --entrypoint node --memory 512m \
    -v "$INSTALL_DIR:/cleaner:ro" \
    -v "$CONFIG_DIR:/sharkey/.config:ro" \
    -v "$STATE_DIR:/state" \
    -e SHARKEY_HOME="$SHARKEY_HOME" \
    -e DRY_RUN=0 -e EXPIRY_DAYS="$EXPIRY_DAYS" -e BATCH="$BATCH" \
    -e MAX_MINUTES="$PER_PASS_MINUTES" -e SLEEP_MS="$SLEEP_MS" \
    -e STATE_FILE=/state/state.json -e STOP_FILE=/state/STOP \
    "$IMAGE" /cleaner/clean.mjs > "$LOG_DIR/pass$i.log" 2>&1
  deleted=$(grep -o '"deleted":[0-9]*' "$LOG_DIR/pass$i.log" | tail -1 | cut -d: -f2)
  summary=$(grep -o '"SUMMARY":"[A-Z_]*"' "$LOG_DIR/pass$i.log" | tail -1 | cut -d'"' -f4)
  echo "pass $i: deleted=${deleted:-0} summary=${summary:-?} elapsed=$(( $(date +%s) - t0 ))s  (log: $LOG_DIR/pass$i.log)"
  total=$(( total + ${deleted:-0} ))
  [ "${deleted:-0}" -eq 0 ] && { echo "已收敛（本轮 0 删除），累计删除 $total 行"; exit 0; }
  docker rm -f "$name" >/dev/null 2>&1
done
echo "达到最大轮数 $MAX_PASSES，累计删除 $total 行；如仍有删除，加大 MAX_PASSES 再跑一次。"
