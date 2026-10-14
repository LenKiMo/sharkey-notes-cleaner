#!/bin/bash
# sharkey-notes-cleaner 安装脚本（在实例所在宿主机上以 root 运行）
#
#   ./install.sh                     # 自动探测运行时依赖，装文件，跑一次只读预演
#   ./install.sh --enable-timer      # 上述 + 安装并启用每天 04:00 的 systemd timer
#   ./install.sh --expiry-days 180   # 指定保留天数
#   ./install.sh --dry-run-only      # 只跑只读预演，不装任何东西
#   ./install.sh --uninstall         # 停用 timer 并删除装好的文件（不动数据库）
#
# 只做三件事：把文件放到 INSTALL_DIR、写 /etc/default/sharkey-notes-cleaner、可选装 systemd unit。
# 不改镜像、不改应用容器、不改数据库结构（补索引是单独的一份 SQL，需你手动决定）。
set -euo pipefail

VERSION="$(cat "$(dirname "$0")/VERSION" 2>/dev/null || echo dev)"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/sharkey-notes-cleaner}"
ENV_FILE="${ENV_FILE:-/etc/default/sharkey-notes-cleaner}"
UNIT_DIR="/etc/systemd/system"
STATE_DIR="${STATE_DIR:-/var/lib/sharkey-notes-cleaner}"

APP_CONTAINER=""; IMAGE=""; NETWORK=""; CONFIG_DIR=""; EXPIRY_DAYS=""
ENABLE_TIMER=0; DRY_ONLY=0; DO_UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app-container) APP_CONTAINER="$2"; shift 2 ;;
    --image)         IMAGE="$2"; shift 2 ;;
    --network)       NETWORK="$2"; shift 2 ;;
    --config-dir)    CONFIG_DIR="$2"; shift 2 ;;
    --expiry-days)   EXPIRY_DAYS="$2"; shift 2 ;;
    --install-dir)   INSTALL_DIR="$2"; shift 2 ;;
    --enable-timer)  ENABLE_TIMER=1; shift ;;
    --dry-run-only)  DRY_ONLY=1; shift ;;
    --uninstall)     DO_UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行" >&2; exit 1; }
command -v docker >/dev/null || { echo "找不到 docker" >&2; exit 1; }

if [ "$DO_UNINSTALL" -eq 1 ]; then
  systemctl disable --now sharkey-notes-cleaner.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/sharkey-notes-cleaner.timer" "$UNIT_DIR/sharkey-notes-cleaner.service"
  systemctl daemon-reload 2>/dev/null || true
  echo "已停用并删除 systemd unit。"
  echo "保留：$INSTALL_DIR、$STATE_DIR、$ENV_FILE（要一并删除请手动 rm -rf）"
  echo "数据库侧的改动（补的索引）不会回滚——那是独立改进，建议保留。"
  exit 0
fi

# ── 探测运行时依赖 ───────────────────────────────────────────────────────────
# 注意：清理器自己也是「用同一个镜像跑的容器」，探测时必须把它排除，
# 否则会把正在跑的 sharkey-*-cleaner 当成应用容器，并进而挑错 db 容器。
detect() {
  local cand
  cand="$(docker ps --format '{{.Names}}|{{.Image}}|{{.Command}}' | grep -viE 'postgres|pgroonga|redis|cleaner|clean\.mjs' || true)"
  if [ -z "$APP_CONTAINER" ]; then
    # ① 镜像名像 Sharkey/Misskey 的容器
    APP_CONTAINER="$(echo "$cand" | awk -F'|' 'tolower($2) ~ /sharkey|misskey/ {print $1; exit}')"
  fi
  if [ -z "$APP_CONTAINER" ]; then
    # ② 退一步：名字像应用、且挂着 /sharkey/.config 的容器
    APP_CONTAINER="$(echo "$cand" | awk -F'|' 'tolower($1) ~ /web|app|sharkey|misskey/ {print $1; exit}')"
  fi
  [ -n "$APP_CONTAINER" ] || { echo "探测不到应用容器，请用 --app-container 指定（清理器/数据库容器已被排除）" >&2; exit 1; }
  echo "应用容器: $APP_CONTAINER"

  [ -n "$IMAGE" ] || IMAGE="$(docker inspect -f '{{.Config.Image}}' "$APP_CONTAINER")"
  echo "镜像:     $IMAGE"
  [ -n "$NETWORK" ] || NETWORK="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$APP_CONTAINER")"
  if [ -n "$NETWORK" ]; then
    # 应用容器可能接了多个网络（compose 项目网络 + 外部共享网络）。
    # 优先 compose 默认网络（*_default，db 服务名在其中可解析），其次项目名网络，最后取第一个。
    _proj="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$APP_CONTAINER" 2>/dev/null || true)"
    _n="$(printf '%s\n' "$NETWORK" | grep -E '_default$' | head -1 || true)"
    [ -n "$_n" ] || { [ -n "$_proj" ] && _n="$(printf '%s\n' "$NETWORK" | grep -F "$_proj" | head -1 || true)"; }
    [ -n "$_n" ] || _n="$(printf '%s\n' "$NETWORK" | head -1)"
    NETWORK="$_n"
  fi
  echo "网络:     $NETWORK"

  if [ -z "$CONFIG_DIR" ]; then
    CONFIG_DIR="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/sharkey/.config"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "$APP_CONTAINER" | head -1)"
  fi
  if [ -z "$CONFIG_DIR" ]; then
    local wd; wd="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$APP_CONTAINER" 2>/dev/null || true)"
    [ -n "$wd" ] && [ -d "$wd/.config" ] && CONFIG_DIR="$wd/.config"
  fi
  [ -n "$CONFIG_DIR" ] || { echo "探测不到 .config 目录，请用 --config-dir 指定" >&2; exit 1; }
  echo "配置目录: $CONFIG_DIR"
  [ -d "$CONFIG_DIR" ] || { echo "配置目录不存在: $CONFIG_DIR（用 --config-dir 指定）" >&2; exit 1; }

  # 硬校验：应用容器里必须真的有 ormconfig.js（清理器就靠它连库）
  if ! docker exec "$APP_CONTAINER" test -f /sharkey/packages/backend/ormconfig.js; then
    echo "⚠️ 在 $APP_CONTAINER 里找不到 /sharkey/packages/backend/ormconfig.js —— 可能选错了容器；请用 --app-container 指定" >&2
    exit 1
  fi

  # db 容器：优先「同一个 compose 项目」里的 postgres/pgroonga，其次按名字猜，最后才取第一个
  local proj
  proj="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$APP_CONTAINER" 2>/dev/null || true)"
  DB_CONTAINER="$(docker ps --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}' \
    | grep -E 'postgres|pgroonga' | awk -F'|' -v p="$proj" 'p!="" && $3==p {print $1; exit}')"
  [ -n "$DB_CONTAINER" ] || DB_CONTAINER="$(docker ps --format '{{.Names}}|{{.Image}}' | grep -E 'postgres|pgroonga' | grep -iE 'sharkey|misskey|shonk' | head -1 | cut -d'|' -f1 || true)"
  [ -n "$DB_CONTAINER" ] || DB_CONTAINER="$(docker ps --format '{{.Names}}|{{.Image}}' | grep -E 'postgres|pgroonga' | head -1 | cut -d'|' -f1 || true)"
  echo "db 容器:  ${DB_CONTAINER:-（未探测到）}"
}

psql_db() { docker exec -i "$DB_CONTAINER" sh -c 'psql -q -U $POSTGRES_USER -d $POSTGRES_DB' ; }

detect

# ── 只读预演 ─────────────────────────────────────────────────────────────────
dry_run() {
  echo "── 只读预演（不动任何数据） ──"
  docker run --rm --name sharkey-notes-cleaner-dryrun \
    --network "$NETWORK" --entrypoint node --memory 512m \
    -v "$SRC_DIR/clean.mjs:/cleaner/clean.mjs:ro" \
    -v "$CONFIG_DIR:/sharkey/.config:ro" \
    -e DRY_RUN=1 -e EXPIRY_DAYS="${EXPIRY_DAYS:-90}" -e BATCH=1000 \
    "$IMAGE" /cleaner/clean.mjs 2>&1 | grep -v 'Reading configuration' | tail -3
}

if [ "$DRY_ONLY" -eq 1 ]; then dry_run; exit 0; fi

# ── 装文件 ───────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" "$STATE_DIR"
install -m 0644 "$SRC_DIR/clean.mjs"   "$INSTALL_DIR/clean.mjs"
install -m 0755 "$SRC_DIR/run.sh"      "$INSTALL_DIR/run.sh"
install -m 0644 "$SRC_DIR/README.md"   "$INSTALL_DIR/README.md" 2>/dev/null || true
install -m 0644 "$SRC_DIR/VERSION"     "$INSTALL_DIR/VERSION" 2>/dev/null || true
mkdir -p "$INSTALL_DIR/sql" "$INSTALL_DIR/docs"
cp -f "$SRC_DIR"/sql/*.sql "$INSTALL_DIR/sql/" 2>/dev/null || true
cp -f "$SRC_DIR"/docs/* "$INSTALL_DIR/docs/" 2>/dev/null || true
echo "已安装到 $INSTALL_DIR"

if [ ! -f "$ENV_FILE" ]; then
  sed -e "s|^CLEANER_IMAGE=.*|CLEANER_IMAGE=$IMAGE|" \
      -e "s|^CLEANER_NETWORK=.*|CLEANER_NETWORK=$NETWORK|" \
      -e "s|^CLEANER_CONFIG_DIR=.*|CLEANER_CONFIG_DIR=$CONFIG_DIR|" \
      -e "s|^EXPIRY_DAYS=.*|EXPIRY_DAYS=${EXPIRY_DAYS:-90}|" \
      "$SRC_DIR/env.example" > "$ENV_FILE"
  chmod 0644 "$ENV_FILE"
  echo "已写入配置 $ENV_FILE"
else
  echo "配置已存在，未覆盖：$ENV_FILE"
fi

# ── 索引体检（只查不改） ──────────────────────────────────────────────────────
if [ -n "${DB_CONTAINER:-}" ]; then
  echo "── 外键子表索引体检（缺索引会让每次删帖全表扫子表） ──"
  psql_db < "$INSTALL_DIR/sql/01-check-missing-fk-indexes.sql" || true
  echo "若上面有输出，参考 $INSTALL_DIR/sql/02-add-missing-indexes.sql 自行决定是否补索引。"
else
  echo "未探测到 db 容器，跳过索引体检。SQL 见 $INSTALL_DIR/sql/。"
fi

# ── 安装后立刻做一次只读预演 ─────────────────────────────────────────────────
dry_run || true

# ── systemd ─────────────────────────────────────────────────────────────────
if [ "$ENABLE_TIMER" -eq 1 ]; then
  install -m 0644 "$SRC_DIR/systemd/sharkey-notes-cleaner.service" "$UNIT_DIR/sharkey-notes-cleaner.service"
  install -m 0644 "$SRC_DIR/systemd/sharkey-notes-cleaner.timer"   "$UNIT_DIR/sharkey-notes-cleaner.timer"
  systemctl daemon-reload
  systemctl enable --now sharkey-notes-cleaner.timer
  echo "已启用 sharkey-notes-cleaner.timer（systemctl list-timers | grep sharkey-notes-cleaner）"
else
  echo "未启用定时器。确认无误后执行："
  echo "  install -m 0644 $SRC_DIR/systemd/sharkey-notes-cleaner.service $UNIT_DIR/"
  echo "  install -m 0644 $SRC_DIR/systemd/sharkey-notes-cleaner.timer   $UNIT_DIR/"
  echo "  systemctl daemon-reload && systemctl enable --now sharkey-notes-cleaner.timer"
  echo "  或直接：$0 --enable-timer"
fi

echo
echo "下一步建议："
echo "  1) 复核只读预演结果，确认保留天数（当前 EXPIRY_DAYS=${EXPIRY_DAYS:-90}）"
echo "  2) 先手工实删一小批：EXPIRY_DAYS=90 BATCH=200 MAX_NOTES=500 MAX_MINUTES=2 $INSTALL_DIR/run.sh"
echo "  3) 核对应用健康与 pg_stat_user_tables.n_tup_del 增量后，再放开批量跑"
echo "  4) 长期：systemctl enable --now sharkey-notes-cleaner.timer（每天 04:00）"
echo "  5) 空间真正归还 OS 需另行 VACUUM FULL（见 README「空间回收」）"
echo "版本：sharkey-notes-cleaner $VERSION"
