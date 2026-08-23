#!/usr/bin/env bash
# ストアの comet.app を常用の場所へ入れ替える。
#
# **なぜストアから直接動かさないのか。** アクセシビリティ権限はコード署名の同一性に
# 紐づく。ストアの中では ad-hoc 署名しかできず、内容が変わるたびに cdhash が変わって
# 権限が外れる。固定の署名 ID（既定 `comet-dev`）で署名し直せば、更新しても
# 権限を付け直さずに済む。キーチェーンに触れるのは activation の中だけなので、
# 署名し直しはここで行う。
#
# 冪等。ストアのパスが前回と同じなら**何もしない**（常駐中の comet を落とさない）。
#
# 環境変数:
#   COMET_SOURCE_APP        ストアの comet.app（必須）
#   COMET_DESTINATION       入れる先（必須。例 ~/Applications/comet.app）
#   COMET_SIGNING_IDENTITY  署名し直しに使う ID。空なら ad-hoc のまま
#   COMET_LAUNCHD_LABEL     launchd のラベル。空なら launchd を触らない
#   COMET_STATE_DIR         導入済みのストアパスを覚えておく場所
#   COMET_STANDALONE        1 なら、ラベル未指定でも登録済みの agent を探し、
#                           登録が無ければ `open` で直接起動する（`nix run .#install` 用）。
#                           モジュールからの呼び出しでは設定しない（宣言に無い起動をしないため）

set -euo pipefail

# activation の PATH には launchctl / codesign / security が無いことがある。
PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"

source_app="${COMET_SOURCE_APP:?COMET_SOURCE_APP が未設定}"
destination="${COMET_DESTINATION:?COMET_DESTINATION が未設定}"
signing_identity="${COMET_SIGNING_IDENTITY:-}"
label="${COMET_LAUNCHD_LABEL:-}"
state_dir="${COMET_STATE_DIR:-$HOME/Library/Application Support/comet}"
standalone="${COMET_STANDALONE:-}"

stamp="$state_dir/installed-store-path"

log() { printf 'comet: %s\n' "$*"; }

# 単体で走らせたときは、どのモジュールが登録した agent かを問わず拾う。
# ProgramArguments が入れ替え先を指している plist を探して、そのラベルを使う。
discover_label() {
  local candidate found
  for candidate in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$candidate" ] || continue
    grep -qF "$destination/Contents/MacOS/comet" "$candidate" 2>/dev/null || continue
    found="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$candidate" 2>/dev/null)" || continue
    if [ -n "$found" ]; then
      printf '%s' "$found"
      return 0
    fi
  done
  return 1
}

if [ -z "$label" ] && [ -n "$standalone" ]; then
  label="$(discover_label || true)"
  if [ -n "$label" ]; then
    log "launchd の登録を見つけた: $label"
  fi
fi

service="gui/$(id -u)/$label"

# launchd の plist の場所。home-manager も nix-darwin も `<ラベル>.plist` に置くが、
# 置き方が変わっても拾えるよう、無ければラベルで中身を探す。
find_plist() {
  [ -n "$label" ] || return 1
  local candidate
  candidate="$HOME/Library/LaunchAgents/$label.plist"
  if [ -f "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  candidate="$(grep -lsF "<string>$label</string>" \
    "$HOME"/Library/LaunchAgents/*.plist 2>/dev/null | head -1)" || true
  if [ -n "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

# ---- 何も変わっていなければ触らない ------------------------------------------
# 印はバンドルの**外**に置く。中に置くと署名の対象に入って検証が落ちる。
if [ -x "$destination/Contents/MacOS/comet" ] \
  && [ -f "$stamp" ] \
  && [ "$(cat "$stamp")" = "$source_app" ]; then
  exit 0
fi

log "$destination を入れ替える"
log "  <- $source_app"

# ---- 動いているものを止める --------------------------------------------------
# バンドルを差し替えると署名の検証に失敗して落ちるので、先に止める。
#
# **bootout したら必ず bootstrap で戻すこと。** 戻さないと登録が消えたままになり、
# 以後 kickstart が「サービスが無い」で失敗する。
was_loaded=0
if [ -n "$label" ] && launchctl print "$service" >/dev/null 2>&1; then
  was_loaded=1
  log "  launchd の登録を一旦外す"
  launchctl bootout "$service" 2>/dev/null || true
  # 落ちきるのを待つ。待たずに差し替えると古いプロセスが新しいバンドルを掴む。
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$service" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

if pgrep -f "$destination/Contents/MacOS/comet" >/dev/null 2>&1; then
  log "  動いている comet を止める"
  pkill -INT -f "$destination/Contents/MacOS/comet" 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do
    pgrep -f "$destination/Contents/MacOS/comet" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

# ---- 入れ替える --------------------------------------------------------------
mkdir -p "$(dirname "$destination")" "$state_dir"
rm -rf "$destination.new" "$destination"
cp -R "$source_app" "$destination.new"
# ストアから来たものは読み取り専用。署名し直すために書けるようにする。
chmod -R u+w "$destination.new"
mv "$destination.new" "$destination"

# ---- 固定の署名 ID で署名し直す ----------------------------------------------
if [ -n "$signing_identity" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$signing_identity\""; then
    if codesign --force --sign "$signing_identity" \
        --identifier local.comet "$destination" >/dev/null 2>&1; then
      log "  署名 ID: ${signing_identity}（更新してもアクセシビリティ権限を保てる）"
    else
      log "  警告: $signing_identity での署名に失敗した。ad-hoc のまま進める"
      log "        キーチェーンがロックされているか、codesign に許可が無い可能性がある"
    fi
  else
    log "  警告: 署名 ID \"$signing_identity\" がキーチェーンに無い。ad-hoc のまま進める"
    log "        ad-hoc は更新のたびに cdhash が変わるので権限を付け直すことになる"
    log "        固定 ID を作る: ./scripts/make-signing-cert.sh"
  fi
fi

# ---- 登録を戻す --------------------------------------------------------------
if plist="$(find_plist)"; then
  log "  launchd へ登録し直して起動する"
  launchctl bootout "$service" 2>/dev/null || true
  # 一時的に失敗することがある（"Operation already in progress" 等）。
  # switch 全体を落とすほどのことではないので、下の生存確認に判断を任せる。
  if ! launchctl bootstrap "$(dirname "$service")" "$plist"; then
    log "  警告: launchd への登録に失敗した"
  fi
  # 上がったかどうかは activation を失敗させるほどのことではないので、
  # 知らせるだけにする。落ちている理由はログに出ている。
  for _ in 1 2 3 4 5 6 7 8; do
    if pgrep -f "$destination/Contents/MacOS/comet" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  if ! pgrep -f "$destination/Contents/MacOS/comet" >/dev/null 2>&1; then
    log "  警告: 起動を確認できなかった。ログ: ~/Library/Logs/comet.log"
  fi
elif [ "$was_loaded" = 1 ]; then
  log "  警告: $label の plist が見つからず launchd へ戻せなかった"
elif [ -n "$standalone" ]; then
  log "  launchd の登録が無いので直接起動する"
  open "$destination"
fi

printf '%s' "$source_app" > "$stamp"
log "完了: $destination"
