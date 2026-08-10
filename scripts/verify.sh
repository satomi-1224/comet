#!/bin/bash
# 実機検証をまとめて回す。
#
# 手で押さないと確かめられなかった項目（キー連射・縁のドラッグ）も、
# comet 自身から合成イベントを送って機械的に判定する。
#
# 使い方: ./scripts/verify.sh
#
# やること:
#   1. AeroSpace を止める（終了時に必ず戻す）
#   2. アプリバンドルを組み立てる（素の実行ファイルは権限を保てない）
#   3. 検証項目ごとに comet を起動し、ログを検証する
#   4. AeroSpace を戻す
#
# 終了コード: 0 = 全て通った / 1 = 失敗あり

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

APP="$REPO_ROOT/build/comet.app/Contents/MacOS/comet"
WORK="$(mktemp -d /tmp/comet-verify.XXXXXX)"
CONFIG="$WORK/config.toml"
AEROSPACE_WAS_RUNNING=0
PASS=0
FAIL=0

# ---- 後片付け -------------------------------------------------------------
# 途中で失敗しても AeroSpace は必ず戻す。ここを怠ると利用者の環境が壊れたままになる。
cleanup() {
  pkill -INT -f "comet.app/Contents/MacOS/comet" 2>/dev/null
  sleep 2
  if [ "$AEROSPACE_WAS_RUNNING" = "1" ] && ! pgrep -f AeroSpace >/dev/null; then
    echo "==> AeroSpace を戻す"
    open -a AeroSpace 2>/dev/null
    sleep 3
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ---- 判定 ---------------------------------------------------------------
ok() { printf '  \033[32m通過\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf '  \033[31m失敗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ログに現れることを期待する
expect_log() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE "$pattern" "$file"; then ok "$label"; else
    ng "$label"
    echo "        期待した記録: $pattern"
  fi
}

# ログに現れないことを期待する
expect_no_log() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE "$pattern" "$file"; then
    ng "$label"
    grep -E "$pattern" "$file" | head -2 | sed 's/^/        /'
  else ok "$label"; fi
}

# bash 3.2 は多バイト文字を変数名の一部として読む。全角が続く変数は必ず ${} で囲むこと。
expect_count() {
  local file="$1" pattern="$2" want="$3" label="$4"
  local got
  got="$(grep -cE "$pattern" "$file" || true)"
  if [ "$got" -ge "$want" ]; then ok "${label}（$got 回）"; else
    ng "${label}（$got 回、$want 回以上を期待）"
  fi
}

# comet を起動してログが落ち着くまで待つ。第2引数はログレベル。
start_comet() {
  local log="$1" level="$2"
  shift 2
  "$APP" --config "$CONFIG" --log-level "$level" "$@" >"$log" 2>&1 &
  echo $! >"$WORK/pid"
  sleep 4
}

stop_comet() {
  if [ -f "$WORK/pid" ]; then
    kill -INT "$(cat "$WORK/pid")" 2>/dev/null
    sleep 3
    rm -f "$WORK/pid"
  fi
}

# ---- 準備 ---------------------------------------------------------------
echo "==> 準備"
if pgrep -f AeroSpace >/dev/null; then
  AEROSPACE_WAS_RUNNING=1
  echo "    AeroSpace を止める（検証後に戻す）"
  osascript -e 'quit app "AeroSpace"' 2>/dev/null
  sleep 2
fi

"$REPO_ROOT/scripts/build-app.sh" debug >"$WORK/build.log" 2>&1 || {
  echo "アプリバンドルの組み立てに失敗した。$WORK/build.log を見る" >&2
  exit 1
}
[ -x "$APP" ] || { echo "$APP が無い" >&2; exit 1; }

# 検証用の設定。他の WM と衝突しないキーだけを使い、計測を有効にする。
cat >"$CONFIG" <<'TOML'
[workspaces]
count  = 3
hidden = "hide-app"

[gaps]
inner-horizontal = 5
inner-vertical   = 5
outer-top        = 5
outer-bottom     = 5
outer-left       = 5
outer-right      = 5

[debug]
timing = true

[mode.main.binding]
ctrl-alt-shift-y = "resize width +40"
ctrl-alt-shift-u = "focus right"
TOML

# ---- 1. 起動時のタイル配置 ------------------------------------------------
echo "==> 1. 起動時のタイル配置"
start_comet "$WORK/1.log" debug
expect_log "$WORK/1.log" "起動時の走査が完了: ウィンドウ [1-9]" "ウィンドウを認識した"
expect_no_log "$WORK/1.log" "1枚も認識できなかった" "権限が生きている"
expect_no_log "$WORK/1.log" "レイアウトを算出できなかった" "レイアウトを算出できた"
expect_no_log "$WORK/1.log" "領域が足りず" "全ウィンドウを配置できた"
stop_comet
expect_log "$WORK/1.log" "(表示に戻した|画面へ戻す|退避していた|SIGINT)" "終了処理が走った"

# ---- 2. キー連射（症状B の前提） -------------------------------------------
# 「押しっぱなしでコマンドが繰り返し発火するか」が症状B の前提。
# OS のキー連射は keyUp を挟まない keyDown の連続なので、それを再現して数える。
echo "==> 2. 押しっぱなしでコマンドが繰り返されるか"
start_comet "$WORK/2.log" trace
# Carbon のホットキーはキー連射では1回しか発火しない（実測）。comet は離されるまで
# 自分で繰り返す。resize だけが対象で、focus は繰り返さないこと。
"$APP" --emit-key "ctrl-alt-shift-y:20" >/dev/null 2>&1
sleep 1
expect_count "$WORK/2.log" "コマンド: resize width \+40" 5 "押しっぱなしで resize が繰り返された"
"$APP" --emit-key "ctrl-alt-shift-u:20" >/dev/null 2>&1
sleep 1
FOCUS_COUNT="$(grep -cE "コマンド: focus right" "$WORK/2.log" || true)"
if [ "$FOCUS_COUNT" -le 2 ]; then
  ok "focus は繰り返さない（$FOCUS_COUNT 回）"
else
  ng "focus が繰り返された（$FOCUS_COUNT 回、2 回以下を期待）"
fi
expect_no_log "$WORK/2.log" "(fatal error|Fatal error)" "連射でクラッシュしなかった"
stop_comet

# ---- 3. ワークスペース切替と非表示 ----------------------------------------
echo "==> 3. ワークスペース切替（アプリごと非表示）"
# 隠す → 戻す → もう一度隠す。最後に隠れた状態で終わらせて終了処理も見る。
start_comet "$WORK/3.log" debug \
  --run "workspace 2" --run "focus right" \
  --run "workspace 1" --run "focus right" \
  --run "workspace 2" --run "focus right"
sleep 3
expect_log "$WORK/3.log" "アプリを非表示にした" "非表示ワークスペースのアプリを隠した"
expect_log "$WORK/3.log" "非表示アプリ [1-9]" "隠れているアプリを状態に出せた"
expect_log "$WORK/3.log" "アプリを表示に戻した" "戻ってきたときに表示へ戻した"
stop_comet
expect_log "$WORK/3.log" "非表示にしていた [1-9] 個のアプリを表示に戻した" "終了時に全て戻した"

# ---- 4. 縁のドラッグ追従 --------------------------------------------------
# 分割の境界を掴んで引いたときに、隣が追従して間隔が保たれるか。
echo "==> 4. 縁のドラッグで隣が追従するか"
start_comet "$WORK/4.log" trace
# 最初のウィンドウの右端を目標矩形から読む。"→ (x, y) WxH" の形で出ている。
GEOM="$(grep -oE '→ \([0-9]+, [0-9]+\) [0-9]+x[0-9]+' "$WORK/4.log" | head -1 || true)"
if [ -z "$GEOM" ]; then
  # dry-run でないときは適用ログに矩形が出ないので、状態から拾えない。
  ng "ドラッグの起点を決められなかった（配置ログが無い）"
  stop_comet
else
  X=$(echo "$GEOM" | sed -E 's/→ \(([0-9]+), ([0-9]+)\) ([0-9]+)x([0-9]+)/\1/')
  Y=$(echo "$GEOM" | sed -E 's/→ \(([0-9]+), ([0-9]+)\) ([0-9]+)x([0-9]+)/\2/')
  W=$(echo "$GEOM" | sed -E 's/→ \(([0-9]+), ([0-9]+)\) ([0-9]+)x([0-9]+)/\3/')
  H=$(echo "$GEOM" | sed -E 's/→ \(([0-9]+), ([0-9]+)\) ([0-9]+)x([0-9]+)/\4/')
  EDGE_X=$((X + W))
  EDGE_Y=$((Y + H / 2))
  echo "    起点 (${EDGE_X}, ${EDGE_Y}) を左へ 150 引く"
  "$APP" --emit-drag "${EDGE_X},${EDGE_Y}:-150,0" >/dev/null 2>&1
  sleep 3
  expect_log "$WORK/4.log" "リサイズを分割の比率へ反映" "ドラッグを境界の移動として解釈した"
  expect_no_log "$WORK/4.log" "レイアウトへ戻す" "移動と誤認しなかった"
  expect_no_log "$WORK/4.log" "が [0-9]+ 秒で [0-9]+ 回以上動かされた" "追従が暴走しなかった"
  stop_comet
fi

# ---- 5. 設定のホットリロード ----------------------------------------------
echo "==> 5. 設定のホットリロード"
start_comet "$WORK/5.log" debug
# 上書き保存（内容だけ変わる）
sed -i '' 's/inner-horizontal = 5/inner-horizontal = 20/' "$CONFIG"
sleep 2
# rename での差し替え（vim / home-manager 方式）
sed 's/inner-horizontal = 20/inner-horizontal = 8/' "$CONFIG" >"$WORK/next.toml"
mv "$WORK/next.toml" "$CONFIG"
sleep 2
expect_count "$WORK/5.log" "設定を読み直した" 2 "上書き保存と rename の両方で読み直した"
stop_comet

# ---- 6. 計測 -------------------------------------------------------------
echo "==> 6. 計測"
expect_log "$WORK/2.log" "計測: (setPosition|setSize)" "アプリ別のレイテンシを集計できた"

# ---- まとめ -------------------------------------------------------------
echo ""
echo "==> 結果: 通過 $PASS / 失敗 $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "    ログ: $WORK （このあと消える。残したいなら実行中に別へ写す）"
  # 失敗したログを残す
  mkdir -p "$REPO_ROOT/build/verify-logs"
  cp "$WORK"/*.log "$REPO_ROOT/build/verify-logs/" 2>/dev/null
  echo "    控え: build/verify-logs/"
  exit 1
fi
exit 0
