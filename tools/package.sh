#!/bin/bash
# 打可分发压缩包（tar.gz + zip），输出到 ../../dist/
# 用法：bash tools/package.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NAME="sharkey-notes-cleaner"
VER="$(cat "$ROOT/VERSION")"
OUT="$(cd "$ROOT/.." && pwd)/dist"
mkdir -p "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$NAME-$VER"
mkdir -p "$PKG"
for f in clean.mjs run.sh install.sh env.example README.md CHANGELOG.md VERSION LICENSE .gitignore .gitattributes; do
  [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$PKG/$f"
done
cp -r "$ROOT/systemd" "$ROOT/sql" "$ROOT/docs" "$ROOT/tools" "$PKG/"
chmod 0755 "$PKG/run.sh" "$PKG/install.sh"
chmod 0644 "$PKG/clean.mjs"

( cd "$STAGE" && tar czf "$OUT/$NAME-$VER.tar.gz" "$NAME-$VER" )

# zip 需要一个真正可用的 python（Windows 上 python3 可能是商店占位符）
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import zipfile,sys; sys.exit(0)' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -n "$PY" ]; then
  # 原生 python（Windows）不认 MSYS 路径，转成 F:/... 形式
  OUTP="$OUT"
  command -v cygpath >/dev/null 2>&1 && OUTP="$(cygpath -m "$OUT")"
  ( cd "$STAGE" && "$PY" - "$NAME-$VER" "$OUTP/$NAME-$VER.zip" ) <<'PYEOF'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
root = os.path.basename(src.rstrip('/'))
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    for base, _dirs, files in os.walk(src):
        for f in files:
            p = os.path.join(base, f)
            z.write(p, os.path.join(root, os.path.relpath(p, src)))
    print('zip entries:', len(z.namelist()))
PYEOF
else
  echo "WARN: 找不到可用的 python，跳过 .zip（.tar.gz 已生成）" >&2
fi
ls -la "$OUT"
echo "校验："
tar tzf "$OUT/$NAME-$VER.tar.gz" | sort | head -20
