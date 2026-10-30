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
APP_CONTAINER="${CLEANER_APP_CONTAINER:-sharkey-web}"
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

# ── 镜像可用性自愈 ───────────────────────────────────────────────────────────
# 配置里的 tag 可能在「换镜像 / 镜像被 prune」之后消失（典型：第三方镜像线停更、
# 切到自建镜像后旧 tag 被清掉）。此时绝不能盲拉 registry：本地自建镜像名不在任何
# registry 里，docker 会报 pull access denied 并以 rc=125 退出，systemd 只留下一行
# 「rc=125」，看不出根因。这里改为退回「运行中应用容器正在用的镜像 ID」（sha256，
# 永不触发 pull），并明确打印 WARN。
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  _used_container=""
  for _c in "$APP_CONTAINER" sharkey-web sharkey app web; do
    [ -n "$_c" ] || continue
    _live_id="$(docker inspect -f '{{.Image}}' "$_c" 2>/dev/null)" || continue
    [ -n "$_live_id" ] || continue
    docker image inspect "$_live_id" >/dev/null 2>&1 || continue
    IMAGE="$_live_id"
    _used_container="$_c"
    break
  done
  if [ -n "$_used_container" ]; then
    echo "WARN: CLEANER_IMAGE 本地不存在，已退回容器 $_used_container 正在使用的镜像 $IMAGE"
    echo "WARN: 请把 $ENV_FILE 的 CLEANER_IMAGE 同步成该容器当前的镜像 tag（重跑 install.sh 会自动同步）" >&2
  else
    echo "FATAL: CLEANER_IMAGE 本地不存在，且探测不到可用的应用容器镜像（候选：$APP_CONTAINER / sharkey-web / sharkey）" >&2
    echo "       未执行 docker run。请核对 $ENV_FILE 的 CLEANER_IMAGE，或 docker ps 确认应用容器在跑。" >&2
    if [ -n "$NOTIFY_CMD" ] && [ -x "$NOTIFY_CMD" ]; then
      "$NOTIFY_CMD" "⚠️ sharkey-notes-cleaner 未执行：镜像缺失
CLEANER_IMAGE 本地不存在，且找不到应用容器镜像
（配置：$ENV_FILE）" || true
    fi
    exit 66
  fi
fi

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1

docker run --rm --pull never --name "$CONTAINER_NAME" \
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
