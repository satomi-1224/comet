#!/bin/bash
# comet.app を常用の場所へ入れる。
#
# **`build/comet.app` は常用に向かない。** `build-app.sh` が毎回消して作り直すため、
# ログイン項目や launchd が指す先が一瞬消える（実際に常駐が落ちた）。
# 固定の場所（`~/Applications/comet.app`）へ置いてそこから起動する。
#
# 使い方:
#   ./scripts/install-app.sh [debug|release]
#
# やること:
#   1. アプリバンドルを組み立てる
#   2. ~/Applications/comet.app へ入れ替える（動いていれば止めてから）
#   3. launchd の登録があれば読み直させる
#
# **アクセシビリティ権限について**: 権限はコード署名の同一性に紐づく。ad-hoc 署名は
# 内容が変わるたびにハッシュが変わるので、入れ替えるたびに確認ダイアログが出る。
# `./scripts/make-signing-cert.sh` で固定の署名 ID を作ると出なくなる。

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

CONFIGURATION="${1:-release}"
DESTINATION="$HOME/Applications/comet.app"
# home-manager が置く launchd のラベル。
AGENT="gui/$(id -u)/org.nix-community.home.comet"

"$REPO_ROOT/scripts/build-app.sh" "$CONFIGURATION" || exit 1

PLIST="$HOME/Library/LaunchAgents/org.nix-community.home.comet.plist"

echo "==> 入れ替え: ${DESTINATION}"
# 動いているものは止める。バンドルを差し替えると署名の検証に失敗して落ちる。
#
# **`bootout` したら必ず `bootstrap` で戻す。** 戻さないと launchd の登録が
# 消えたままになり、以後 `kickstart` が「サービスが無い」で失敗する（実際に踏んだ）。
WAS_LOADED=0
if launchctl print "$AGENT" >/dev/null 2>&1; then
  WAS_LOADED=1
  echo "    launchd の登録を一旦外す"
  launchctl bootout "$AGENT" 2>/dev/null || true
  sleep 2
fi
if pgrep -f "$DESTINATION/Contents/MacOS/comet" >/dev/null; then
  echo "    動いている comet を止める"
  pkill -INT -f "$DESTINATION/Contents/MacOS/comet" || true
  sleep 3
fi

mkdir -p "$HOME/Applications"
rm -rf "$DESTINATION"
cp -R "$REPO_ROOT/build/comet.app" "$DESTINATION"

# 外した登録を戻す。登録が無い環境（Nix を使っていない場合）は `open` で上げる。
if [ "$WAS_LOADED" = "1" ] || [ -f "$PLIST" ]; then
  echo "==> launchd へ登録して起動する"
  launchctl bootout "$AGENT" 2>/dev/null || true
  launchctl bootstrap "$(dirname "$AGENT")" "$PLIST"
else
  echo "==> launchd の登録が無いので直接起動する"
  open "$DESTINATION"
fi

sleep 4
if pgrep -f "$DESTINATION/Contents/MacOS/comet" >/dev/null; then
  echo "==> 完了。${DESTINATION} で稼働中"
else
  echo "==> 起動を確認できなかった。ログ: ~/Library/Logs/comet.log" >&2
  exit 1
fi
