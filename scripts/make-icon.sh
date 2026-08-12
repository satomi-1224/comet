#!/bin/bash
# アプリのアイコンを作る。
#
# 生成画像（余白と影が付いている）から、**外周から繋がった背景を透明にして**
# 正方形へ切り出し、`Resources/AppIcon.icns` を作る。
#
# 使い方:
#   ./scripts/make-icon.sh <元画像> [comet-probe icon への追加オプション...]
#
# 例（余白のある画像。背景を抜いて図形へ切り詰める）:
#   ./scripts/make-icon.sh ~/Desktop/icon.png --tolerance 100
#
# 例（全面が絵柄の画像。範囲を指定して角を丸める）:
#   ./scripts/make-icon.sh ~/Desktop/image.png --crop 1600,0,1200,1200 --corner-radius 22
#
# --tolerance は「背景とみなす色の幅」。**色だけで一律に抜くのではなく外周から
# 繋がった部分だけを抜く**ので、大きくしても図形の中の明るい部分（グロウ）は消えない。
# --crop を渡すと背景の除去は行わない（余白が無い画像は暗い部分まで抜けてしまうため）。
#
# 作り直したら `./scripts/build-app.sh` でバンドルへ入る。

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

SOURCE="${1:-}"
if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
  echo "使い方: ./scripts/make-icon.sh <元画像> [追加オプション...]" >&2
  exit 2
fi
shift

PROBE="$REPO_ROOT/.build/debug/comet-probe"
[ -x "$PROBE" ] || swift build --product comet-probe >/dev/null

WORK="$(mktemp -d /tmp/comet-icon.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 正方形へ切り出す"
# bash 3.2 の set -u では空配列の展開がエラーになるので要素数で分岐する。
if [ $# -gt 0 ]; then
  "$PROBE" icon "$SOURCE" "$WORK/icon.png" --size 1024 "$@"
else
  "$PROBE" icon "$SOURCE" "$WORK/icon.png" --size 1024
fi

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
