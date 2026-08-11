#!/bin/bash
# アプリのアイコンを作る。
#
# 生成画像（余白と影が付いている）から、**外周から繋がった背景を透明にして**
# 正方形へ切り出し、`Resources/AppIcon.icns` を作る。
#
# 使い方:
#   ./scripts/make-icon.sh ~/Desktop/icon.png [許容差]
#
# 許容差は「背景とみなす色の幅」。影を落としたいので既定は大きめ（100）。
# **色だけで一律に抜くのではなく外周から繋がった部分だけを抜く**ので、
# 図形の中の明るい部分（グロウなど）は許容差を上げても消えない。
#
# 作り直したら `./scripts/build-app.sh` でバンドルへ入る。

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

SOURCE="${1:-}"
TOLERANCE="${2:-100}"
if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
  echo "使い方: ./scripts/make-icon.sh <元画像> [許容差]" >&2
  exit 2
fi

PROBE="$REPO_ROOT/.build/debug/comet-probe"
[ -x "$PROBE" ] || swift build --product comet-probe >/dev/null

WORK="$(mktemp -d /tmp/comet-icon.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 背景を透明にして正方形へ切り出す（許容差 ${TOLERANCE}）"
"$PROBE" icon "$SOURCE" "$WORK/icon.png" --tolerance "$TOLERANCE" --size 1024

echo "==> 各サイズを書き出す"
mkdir -p "$WORK/AppIcon.iconset"
# iconutil は名前で大きさを判断するので、この綴りから外れると失敗する。
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/icon.png" \
    --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" \
    --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done

echo "==> icns へまとめる"
mkdir -p "$REPO_ROOT/Resources"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$REPO_ROOT/Resources/AppIcon.icns"
ls -lh "$REPO_ROOT/Resources/AppIcon.icns" | awk '{print "    " $9 " (" $5 ")"}'
echo "==> 完了。./scripts/build-app.sh でバンドルへ入る"
