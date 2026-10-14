#!/bin/bash
# sharkey-notes-cleaner 定时入口
#
# 由 systemd oneshot 调用（timer 已保证不重入）。读取 /etc/default/sharkey-notes-cleaner，
# 在**同镜像的一次性容器**里跑一次清理，常态静默、只在异常时告警。
#
# 手动用法：  /opt/sharkey-notes-cleaner/run.sh
# 试跑只读：  DRY_RUN=1 /opt/sharkey-notes-cleaner/run.sh
set -uo pipefail

ENV_FILE="${ENV_FILE:-/etc/default/sharkey-notes-cleaner}"
# 调用方显式传入的值优先于配置文件（便于手工试跑/限流，例如 DRY_RUN=1 ... run.sh）
_PRE_DRY_RUN="${DRY_RUN-}"; _PRE_EXPIRY_DAYS="${EXPIRY_DAYS-}"; _PRE_BATCH="${BATCH-}"
_PRE_MAX_MINUTES="${MAX_MINUTES-}"; _PRE_MAX_NOTES="${MAX_NOTES-}"; _PRE_SLEEP_MS="${SLEEP_MS-}"
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
[ -n "$_PRE_DRY_RUN" ]    && DRY_RUN="$_PRE_DRY_RUN"
[ -n "$_PRE_EXPIRY_DAYS" ] && EXPIRY_DAYS="$_PRE_EXPIRY_DAYS"
[ -n "$_PRE_BATCH" ]      && BATCH="$_PRE_BATCH"
[ -n "$_PRE_MAX_MINUTES" ] && MAX_MINUTES="$_PRE_MAX_MINUTES"
[ -n "$_PRE_MAX_NOTES" ]  && MAX_NOTES="$_PRE_MAX_NOTES"
[ -n "$_PRE_SLEEP_MS" ]   && SLEEP_MS="$_PRE_SLEEP_MS"

INSTALL_DIR="${INSTALL_DIR:-/opt/sharkey-notes-cleaner}"
IMAGE="${CLEANER_IMAGE:?CLEANER_IMAGE 未设置（见 $ENV_FILE）}"
NETWORK="${CLEANER_NETWORK:?CLEANER_NETWORK 未设置}"
CONFIG_DIR="${CLEANER_CONFIG_DIR:?CLEANER_CONFIG_DIR 未设置}"
CONTAINER_NAME="${CLEANER_CONTAINER_NAME:-sharkey-notes-cleaner}"
SHARKEY_HOME="${CLEANER_SHARKEY_HOME:-/sharkey}"
NOTIFY_CMD="${CLEANER_NOTIFY_CMD:-}"
STATE_DIR="${CLEANER_STATE_DIR:-/var/lib/sharkey-notes-cleaner}"
STOP_FILE="${CLEANER_STOP_FILE:-$STATE_DIR/STOP}"

mkdir -p "$STATE_DIR"

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1

docker run --rm --name "$CONTAINER_NAME" \
  --network "$NETWORK" --entrypoint node \
  --memory "${CLEANER_MEMORY:-512m}" \
  -v "$INSTALL_DIR:/cleaner:ro" \
  -v "$CONFIG_DIR:/sharkey/.config:ro" \
  -v "$STATE_DIR:/state" \
  -e SHARKEY_HOME="$SHARKEY_HOME" \
  -e DRY_RUN="${DRY_RUN:-1}" \
  -e EXPIRY_DAYS="${EXPIRY_DAYS:-90}" \
  -e BATCH="${BATCH:-2000}" \
  -e MAX_MINUTES="${MAX_MINUTES:-60}" \
  -e MAX_NOTES="${MAX_NOTES:-0}" \
  -e SLEEP_MS="${SLEEP_MS:-500}" \
  -e STATE_FILE="${STATE_FILE:-/state/state.json}" \
  -e STOP_FILE="${STOP_FILE:-/state/STOP}" \
  -e ARCHIVE_DIR="${ARCHIVE_DIR:-}" \
  "$IMAGE" /cleaner/clean.mjs >"$OUT" 2>&1
rc=$?

SUMMARY=$(grep -o '{"SUMMARY".*' "$OUT" | tail -1)
FATAL=$(grep -c '"msg":"fatal"' "$OUT")
FAILED=$(grep -c 'batch-failed' "$OUT")
echo "rc=$rc fatal=$FATAL batch_failed=$FAILED"
echo "${SUMMARY:-（无 SUMMARY 行）}"
cat "$OUT"

# 且仅当异常时告警
if [ "$rc" -ne 0 ] || [ "$FATAL" -gt 0 ] || [ "$FAILED" -gt 8 ]; then
  if [ -x "$NOTIFY_CMD" ]; then
    "$NOTIFY_CMD" "⚠️ sharkey-notes-cleaner 异常：rc=$rc fatal=$FATAL batch_failed=$FAILED
${SUMMARY:-}
（日志：journalctl -u sharkey-notes-cleaner）" || true
  else
    echo "WARN: 未找到通知命令 $NOTIFY_CMD，已跳过告警" >&2
  fi
fi
exit "$rc"
