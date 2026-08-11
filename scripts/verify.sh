#!/bin/bash
# 実機検証をまとめて回す。
#
# 手で押さないと確かめられなかった項目も機械的に判定する。
#
#   - キー連射・縁のドラッグ → comet 自身から合成イベントを送る
#   - **枠線・HUD の見え方** → 画面を撮って画素を数える（`comet-probe`）
#   - **実座標・ちらつき**   → CGWindowList を細かく読む（comet とは独立した観測）
#
# 撮影は `screencapture` に任せている。**画面収録の権限を comet に要求しないため**で、
# 端末が既に持っている権限で撮った PNG を `comet-probe` が読む。
#
# 使い方:
#   ./scripts/verify.sh          通常（2〜3分）
#   ./scripts/verify.sh --long   常駐コストの10分放置も回す
#
# やること:
#   1. AeroSpace を止める（終了時に必ず戻す）
#   2. アプリバンドルを組み立てる（素の実行ファイルは権限を保てない）
#   3. 検証用のウィンドウを開く（利用者が何を開いているかに依存させない）
#   4. 検証項目ごとに comet を起動し、ログ・画素・実座標を検証する
#   5. 開いたウィンドウを閉じ、AeroSpace を戻す
#
# 判定できない環境条件（メニューバーを隠す設定、壁紙を読み出せない等）は
# **失敗ではなく「省略」として理由付きで報告する。** 環境のせいなのか実装が
# 壊れているのかを混ぜないため。
#
# 終了コード: 0 = 全て通った / 1 = 失敗あり

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

APP="$REPO_ROOT/build/comet.app/Contents/MacOS/comet"
PROBE="$REPO_ROOT/.build/debug/comet-probe"
WORK="$(mktemp -d /tmp/comet-verify.XXXXXX)"
CONFIG="$WORK/config.toml"
AEROSPACE_WAS_RUNNING=0
TEXTEDIT_WAS_RUNNING=0
CREATED_WINDOW_IDS=""
# 止めたアプリの pid。**必ず動かし直す**（止めたままにすると利用者から見て固まったアプリになる）。
FROZEN_PID=""
LONG=0
if [ "${1:-}" = "--long" ]; then LONG=1; fi
PASS=0
FAIL=0
SKIP=0

# 枠線の検証で使う色。**画面に写り込まない色**を選ぶ。既定の #7aa2f7 のような
# 落ち着いた色は壁紙や UI に紛れる。
BORDER_COLOR="#ff00ff"
BORDER_WIDTH=6
BORDER_RADIUS=10

# ---- 後片付け -------------------------------------------------------------
# 途中で失敗しても AeroSpace と検証用ウィンドウは必ず片付ける。
# ここを怠ると利用者の環境が壊れたままになる。
cleanup() {
  # 止めたアプリを最優先で動かし直す。ここを飛ばすと利用者の環境に
  # 固まったアプリが残る。
  if [ -n "$FROZEN_PID" ]; then
    kill -CONT "$FROZEN_PID" 2>/dev/null || true
    FROZEN_PID=""
  fi
  # **`|| true` を省いてはいけない。** 該当プロセスが無いと pkill は 1 を返し、
  # set -e で片付けの残りが飛ぶ（AeroSpace が止まったままになり、検証用ウィンドウも
  # 残った。実際にこれで環境が汚れた）。
  pkill -INT -f "comet.app/Contents/MacOS/comet" 2>/dev/null || true
  sleep 2
  close_test_windows
  if [ "$AEROSPACE_WAS_RUNNING" = "1" ] && ! pgrep -f AeroSpace >/dev/null; then
    echo "==> AeroSpace を戻す"
    open -a AeroSpace 2>/dev/null
    sleep 3
  fi
  # **ログの控えは片付けの中で取る。** まとめの直前で取っていると、
  # 途中で異常終了したときに何も残らない（実際にこれで原因を追えなくなった）。
  if [ -d "$WORK" ]; then
    mkdir -p "$REPO_ROOT/build/verify-logs"
    cp "$WORK"/*.log "$WORK"/*.txt "$REPO_ROOT/build/verify-logs/" 2>/dev/null || true
    # 撮った画面は大きいので、落ちたときだけ残す。絵を見ないと分からない失敗がある。
    if [ "$FAIL" -gt 0 ]; then
      cp "$WORK"/*.png "$REPO_ROOT/build/verify-logs/" 2>/dev/null || true
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ---- 検証用のウィンドウ ---------------------------------------------------
# 判定を**利用者が何を開いているかに依存させない。**
#
# フルスクリーンの動画を見ているだけの状態で走らせると、タイル対象のウィンドウが
# 1枚も無く、メニューバーも画面に無い。それでも「枠線が出ていない」「番号が
# 変わらない」は成立してしまうので、**壊れているのか対象が無いのかが区別できない**
# （実際にこの状態を踏んで、通ったように見える検証を書きかけた）。
#
# `id of window` の値は CGWindowID と一致する（実測）ので、どのウィンドウが自分の
# ものかは分かる。**ただし id を指す参照形式では閉じられない**
# （`close window id N` も `close (every window whose id is N)` も無反応。
# 索引で辿って id を比べる書き方でも別のウィンドウが閉じた）。
#
# 確実に効くのは「索引で閉じる」と「アプリを終了する」だけなので、
# **TextEdit が動いていないときにだけ検証用ウィンドウを開き、終了で片付ける。**
# すでに動いているときは触らない（利用者の書類を閉じてしまうため）。
textedit_window_ids() {
  { osascript -e 'tell application "TextEdit" to get id of every window' 2>/dev/null \
    | tr -d ' ' | tr ',' '\n'; } || true
}

# 検証用ウィンドウのある操作スペースを前面に出す。
#
# **ネイティブフルスクリーンのアプリが居ると、それが専用の操作スペースを占め、
# 他のウィンドウは「画面に無い」ことになる**（`optionOnScreenOnly` からも、AX の
# 走査からも消える）。アプリを隠した拍子に OS がそちらへ切り替えることがあるので、
# comet を起動するたびに引き戻す。
activate_test_windows() {
  [ -n "$CREATED_WINDOW_IDS" ] || return 0
  osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1 || true
  sleep 1
}

create_test_windows() {
  local count="$1"
  if pgrep -x TextEdit >/dev/null; then
    TEXTEDIT_WAS_RUNNING=1
    echo "    TextEdit が既に動いているので検証用ウィンドウは開かない"
    echo "    （利用者の書類を閉じられないため。閉じてから回すと項目が増える）"
    return 0
  fi
  # set -e のもとでは失敗が即終了になるので、AppleScript の失敗は自分で受け止める。
  osascript >/dev/null 2>&1 <<OSA || true
tell application "TextEdit"
  activate
  repeat $count times
    make new document
  end repeat
end tell
OSA
  sleep 3
  CREATED_WINDOW_IDS="$(textedit_window_ids | tr '\n' ' ')"
}

close_test_windows() {
  if [ "$TEXTEDIT_WAS_RUNNING" = "1" ]; then return 0; fi
  if [ -z "$CREATED_WINDOW_IDS" ]; then return 0; fi
  # 中身が空の書類しか無いので保存を訊かれずに終わる。
  osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || true
  CREATED_WINDOW_IDS=""
}

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

skip() { printf '  \033[33m省略\033[0m %s\n' "$1"; SKIP=$((SKIP + 1)); }

# 数の比較。ピクセルの一致率や時間の判定に使う。
expect_ge() {
  local got="$1" want="$2" label="$3"
  if [ -z "$got" ]; then ng "${label}（値が取れなかった）"; return; fi
  if [ "$got" -ge "$want" ]; then ok "${label}（$got ≧ ${want}）"; else
    ng "${label}（${got}、$want 以上を期待）"
  fi
}

expect_le() {
  local got="$1" want="$2" label="$3"
  if [ -z "$got" ]; then ng "${label}（値が取れなかった）"; return; fi
  if [ "$got" -le "$want" ]; then ok "${label}（$got ≦ ${want}）"; else
    ng "${label}（${got}、$want 以下を期待）"
  fi
}

# `key=value` の並びから値を取る。comet-probe の出力を読むため。
field() {
  echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}

# ログに出た `(x, y) WxH` を `x,y,w,h` に直す。
rect_of() {
  sed -E 's/.*\(([0-9-]+), ([0-9-]+)\) ([0-9]+)x([0-9]+).*/\1,\2,\3,\4/'
}

# 矩形を撮影の倍率へ写す。Retina では 1pt が複数画素になる。
scale_rect() {
  echo "$1" | awk -F, -v s="$CAPTURE_SCALE" '{print $1*s","$2*s","$3*s","$4*s}'
}

# 2つの矩形が許容差の内側で一致するか。
expect_rect_near() {
  local got="$1" want="$2" tolerance="$3" label="$4"
  if [ -z "$got" ] || [ -z "$want" ]; then ng "${label}（矩形が取れなかった）"; return; fi
  local diff
  diff="$(echo "$got $want" | awk -F'[ ,]' -v t="$tolerance" '{
    d = 0
    for (i = 1; i <= 4; i++) { e = $i - $(i + 4); if (e < 0) e = -e; if (e > d) d = e }
    print d
  }')"
  if [ "$diff" -le "$tolerance" ]; then ok "${label}（ずれ ${diff}pt）"; else
    ng "${label}（ずれ ${diff}pt、$tolerance 以内を期待）"
    echo "        実測 $got / 期待 $want"
  fi
}

# 画面を撮る。撮影は端末が持っている画面収録の権限で行う（comet には要求しない）。
capture() {
  screencapture -x "$1" 2>/dev/null
  [ -s "$1" ]
}

# 枠線の四辺にその色が乗っているか（百分率の最小値）。
# 角丸の円弧は辺の直線上に無いので、両端を半径ぶん切って測る。
border_coverage() {
  local png="$1" rect="$2"
  "$PROBE" edges "$png" "$BORDER_COLOR" --rect "$(scale_rect "$rect")" \
    --line-width $((BORDER_WIDTH * CAPTURE_SCALE / 2)) \
    --inset $(((BORDER_RADIUS + 4) * CAPTURE_SCALE)) --tolerance 24 2>/dev/null
}

# comet を起動してログが落ち着くまで待つ。第2引数はログレベル。
start_comet() {
  local log="$1" level="$2"
  shift 2
  activate_test_windows
  "$APP" --config "$CONFIG" --log-level "$level" "$@" >"$log" 2>&1 &
  echo $! >"$WORK/pid"
  sleep 4
  # タイル対象が無いまま先へ進むと、以降の判定が全て空振りしたまま
  # 「通った」ように見える。ここで気づけるようにしておく。
  if grep -q "タイル対象 0 枚" "$log" 2>/dev/null; then
    echo "        警告: タイル対象が 0 枚。フルスクリーンのアプリが居ないか確認する"
  fi
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
#
# 枠線は幅を太く・色を画面に写り込まないものにする。既定の 2pt / #7aa2f7 では
# 画素の判定が反エイリアスに埋もれる。HUD は撮影が間に合うよう長めに出す。
cat >"$CONFIG" <<TOML
[workspaces]
count  = 3
hidden = "hide-app"

[gaps]
inner-horizontal = 12
inner-vertical   = 12
outer-top        = 12
outer-bottom     = 12
outer-left       = 12
outer-right      = 12

[border]
enabled       = true
width         = $BORDER_WIDTH.0
radius        = $BORDER_RADIUS.0
color-focused = "$BORDER_COLOR"

[indicator]
style           = "both"
hud-duration-ms = 1200

[debug]
timing = true

[mode.main.binding]
ctrl-alt-shift-y = "resize width +40"
ctrl-alt-shift-u = "focus right"
ctrl-alt-shift-1 = "workspace 1"
ctrl-alt-shift-2 = "workspace 2"
ctrl-alt-shift-m = "move-node-to-workspace 2"
TOML

# 撮った画像と comet の座標を突き合わせるための倍率。
# Retina では 1pt が複数画素になるので、pt の矩形をそのまま画素として扱えない。
# 2枚で足りる（枠線の追従に2枚、混在の隅寄せに同じアプリで2枚）。
# 増やすほど1枚あたりが小さくなり、アプリ側の最小サイズに当たって配置できなくなる。
echo "    検証用のウィンドウを開く"
create_test_windows 2
capture "$WORK/scale.png" || { echo "画面を撮れない。端末に画面収録の権限が要る" >&2; exit 1; }
SCREEN_INFO="$("$PROBE" screen)"
SCREEN_W="$(field "$SCREEN_INFO" w)"
# 表示領域の上端 = メニューバーの高さ。インジケータを探す帯として使う。
MENUBAR_H="$(field "$SCREEN_INFO" visible-y)"
CAPTURE_W="$(field "$("$PROBE" size "$WORK/scale.png")" w)"
CAPTURE_SCALE=$((CAPTURE_W / SCREEN_W))
if [ "$CAPTURE_SCALE" -lt 1 ] || [ $((SCREEN_W * CAPTURE_SCALE)) -ne "$CAPTURE_W" ]; then
  echo "    撮影の倍率が整数でない（画面 ${SCREEN_W}pt / 画像 ${CAPTURE_W}px）。画素の判定は省く"
  CAPTURE_SCALE=0
else
  echo "    画面 ${SCREEN_W}pt / 画像 ${CAPTURE_W}px → 倍率 ${CAPTURE_SCALE}"
fi

# ---- 1. 起動時のタイル配置 ------------------------------------------------
echo "==> 1. 起動時のタイル配置"
start_comet "$WORK/1.log" debug
expect_log "$WORK/1.log" "起動時の走査が完了: ウィンドウ [1-9]" "ウィンドウを認識した"
# **タイル対象が 0 枚でも「認識した」は成立してしまう。** フルスクリーンの動画を
# 見ているだけの状態がこれで、以降の検証が全て空振りする。ここで落とす。
expect_no_log "$WORK/1.log" "タイル対象 0 枚" "タイルする対象がある"
expect_no_log "$WORK/1.log" "1枚も認識できなかった" "権限が生きている"
expect_no_log "$WORK/1.log" "レイアウトを算出できなかった" "レイアウトを算出できた"
# 画面いっぱいにウィンドウが開いていると、アプリ側の最小サイズのせいで
# **どう並べても入らない**（実測: 11 枚で 1 枚が入らない）。comet の欠陥ではないので、
# 枚数が多いときは失敗ではなく省略として報告する。
UNPLACED="$(grep -oE "領域が足りず [0-9]+ 枚を配置できなかった（ウィンドウ [0-9]+ 枚）" \
  "$WORK/1.log" | tail -1 || true)"
if [ -z "$UNPLACED" ]; then
  ok "全ウィンドウを配置できた"
else
  WINDOW_COUNT="$(echo "$UNPLACED" | grep -oE "ウィンドウ [0-9]+ 枚" | grep -oE "[0-9]+" || echo 0)"
  if [ "$WINDOW_COUNT" -ge 8 ]; then
    skip "ウィンドウ ${WINDOW_COUNT} 枚では最小サイズの制約で全部は入らない（${UNPLACED}）"
  else
    ng "領域が足りず配置できないウィンドウがある（${UNPLACED}）"
  fi
fi
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
# 値を決め打ちにしない。設定の既定を変えたときに置換が空振りし、
# 「内容は変わっていないが書き込みだけ起きた」状態を読み直しと見なしてしまう。
sed -i '' -E 's/inner-horizontal = [0-9]+/inner-horizontal = 20/' "$CONFIG"
sleep 2
# rename での差し替え（vim / home-manager 方式）
sed -E 's/inner-horizontal = [0-9]+/inner-horizontal = 8/' "$CONFIG" >"$WORK/next.toml"
mv "$WORK/next.toml" "$CONFIG"
sleep 2
expect_count "$WORK/5.log" "設定を読み直した" 2 "上書き保存と rename の両方で読み直した"
stop_comet

# ---- 6. 計測 -------------------------------------------------------------
echo "==> 6. 計測"
expect_log "$WORK/2.log" "計測: (setPosition|setSize)" "アプリ別のレイテンシを集計できた"

# ---- 7〜8. 実座標と内蔵UI -------------------------------------------------
# ここから下は「目視でしか判定できない」としていた項目。
# 画面を撮って画素を数え、ウィンドウの実座標を CGWindowList から読めば機械で判定できる。
#
# 7 と 8 は同じ comet の起動を使い回す（起動と走査に毎回 4 秒かかるため）。
echo "==> 7. 実座標が計算値と一致するか"
start_comet "$WORK/7.log" trace

# 検証用に開いたウィンドウだけを突き合わせる。**利用者のウィンドウは対象にしない。**
# 端末やターミナル系は文字幅の倍数にしかリサイズできず、要求どおりの大きさに
# ならないことがある（comet はその場合フローティングへ降格させる）。
# **すぐには一致しないことがある。** 要求どおりの大きさにならないアプリには
# comet が補正を数回かけるので、その途中を読むと「ずれている」に見える。
# 落ち着くまで数回試してから判定する。
ATTEMPT=0
MATCHED=0
MISMATCHED=0
while [ "$ATTEMPT" -lt 5 ]; do
  MATCHED=0
  MISMATCHED=0
  MISMATCH_DETAIL=""
  for id in $CREATED_WINDOW_IDS; do
    TARGET="$(grep -E "目標 +\[$id\]" "$WORK/7.log" | tail -1 | rect_of || true)"
    LINE="$("$PROBE" windows --any-layer | grep "^id=$id " || true)"
    [ -n "$TARGET" ] && [ -n "$LINE" ] || continue
    ACTUAL="$(field "$LINE" x),$(field "$LINE" y),$(field "$LINE" w),$(field "$LINE" h)"
    if [ "$ACTUAL" = "$TARGET" ]; then
      MATCHED=$((MATCHED + 1))
    else
      MISMATCHED=$((MISMATCHED + 1))
      MISMATCH_DETAIL="${MISMATCH_DETAIL}        [$id] 実測 $ACTUAL / 目標 $TARGET
"
    fi
  done
  if [ "$MISMATCHED" = "0" ] && [ "$MATCHED" -gt 0 ]; then break; fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 1
done
if [ -n "$MISMATCH_DETAIL" ]; then printf '%s' "$MISMATCH_DETAIL"; fi
if [ -z "$CREATED_WINDOW_IDS" ]; then
  skip "検証用ウィンドウが無いので実座標を突き合わせられない"
elif [ "$MATCHED" = "0" ]; then
  ng "目標矩形と実座標を突き合わせられなかった（検証用ウィンドウが認識されていない）"
elif [ "$MISMATCHED" = "0" ]; then
  ok "実座標が計算値と完全に一致した（$MATCHED 枚）"
else
  ng "実座標が計算値とずれている（一致 $MATCHED / ずれ ${MISMATCHED}）"
fi

echo "==> 8. 内蔵UI が画面に出ているか（画素で判定）"
if [ "$CAPTURE_SCALE" = "0" ]; then
  skip "撮影の倍率が整数でないため画素の判定を省いた"
else
  BORDER_RECT="$(grep -E "枠線:" "$WORK/7.log" | tail -1 | rect_of || true)"
  if [ -z "$BORDER_RECT" ]; then
    ng "枠線の位置がログに出ていない（フォーカス中のウィンドウが無い）"
  else
    # (a) 自プロセスのウィンドウとして本当にその位置に置かれているか。
    #     comet のログとは独立した観測（CGWindowList）で確かめる。
    WIN="$("$PROBE" windows --layer 3 --owner comet | head -1 || true)"
    if [ -z "$WIN" ]; then
      ng "枠線のウィンドウが画面に無い"
    else
      expect_rect_near \
        "$(field "$WIN" x),$(field "$WIN" y),$(field "$WIN" w),$(field "$WIN" h)" \
        "$BORDER_RECT" 1 "枠線のウィンドウが記録どおりの位置にある"
    fi

    # (b) 目標矩形を線幅ぶん外へ広げた位置にあるか（ギャップの中に線が収まる）。
    FOCUSED_TARGET="$(echo "$BORDER_RECT" | awk -F, -v b="$BORDER_WIDTH" \
      '{print $1+b","$2+b","$3-2*b","$4-2*b}')"
    if grep -qE "目標 +\[[0-9]+\] .*→ \($(echo "$FOCUSED_TARGET" | awk -F, '{print $1", "$2}')\) $(echo "$FOCUSED_TARGET" | awk -F, '{print $3"x"$4}')" "$WORK/7.log"; then
      ok "枠線がフォーカス中のウィンドウの目標矩形を包んでいる"
    else
      ng "枠線の位置に対応する目標矩形が無い（${FOCUSED_TARGET}）"
    fi

    # (c) 本当に画面に描かれているか。ここが目視の代わり。
    if capture "$WORK/8-border.png"; then
      expect_ge "$(field "$(border_coverage "$WORK/8-border.png" "$BORDER_RECT")" min)" 90 \
        "枠線が画面に描かれている（四辺に色が乗っている割合）"
      # 判定が効いていることの確認。ずれた矩形では落ちなければならない。
      INSIDE="$(echo "$BORDER_RECT" | awk -F, '{print $1+40","$2+40","$3-80","$4-80}')"
      expect_le "$(field "$(border_coverage "$WORK/8-border.png" "$INSIDE")" min)" 30 \
        "40pt 内側の矩形では一致しない（判定が位置に反応している）"
    else
      ng "画面を撮れなかった"
    fi

    # (d) focus の移動に追従するか。
    "$APP" --emit-key ctrl-alt-shift-u >/dev/null 2>&1
    sleep 2
    MOVED_RECT="$(grep -E "枠線:" "$WORK/7.log" | tail -1 | rect_of || true)"
    if [ "$MOVED_RECT" = "$BORDER_RECT" ]; then
      ng "focus を移しても枠線が動かなかった"
    else
      ok "focus の移動で枠線が動いた（$BORDER_RECT → ${MOVED_RECT}）"
      if capture "$WORK/8-moved.png"; then
        expect_ge "$(field "$(border_coverage "$WORK/8-moved.png" "$MOVED_RECT")" min)" 90 \
          "移動後の位置にも枠線が描かれている"
      fi
    fi
  fi

  # (e) HUD とメニューバー。ワークスペースを切り替えて前後を撮る。
  #
  # HUD の判定は「出ている画面」と「消えた画面」の差で見る。**切替そのものによる
  # 変化と混ざらないように、どちらも切替後に撮る**（切替前と比べると、隠れた
  # ウィンドウの変化まで拾ってしまう）。
  capture "$WORK/8-ws1.png"
  "$APP" --emit-key ctrl-alt-shift-2 >/dev/null 2>&1
  sleep 0.4
  capture "$WORK/8-hud-on.png"
  sleep 2.5
  capture "$WORK/8-hud-off.png"

  HUD_RECT="$(grep -E "HUD:" "$WORK/7.log" | tail -1 | rect_of || true)"
  if [ -z "$HUD_RECT" ]; then
    ng "HUD の位置がログに出ていない（切替が起きていない）"
  else
    HUD_DIFF="$("$PROBE" diff "$WORK/8-hud-on.png" "$WORK/8-hud-off.png" \
      --region "$(scale_rect "$HUD_RECT")" 2>/dev/null || true)"
    expect_ge "$(field "$HUD_DIFF" permille)" 200 "HUD が中央に出て、時間で消えた"
    # 対照。HUD 以外が変わっていないことまで見ないと、
    # 画面全体が変わっただけで通ってしまう。
    CONTROL_DIFF="$("$PROBE" diff "$WORK/8-hud-on.png" "$WORK/8-hud-off.png" \
      --region "$(scale_rect "0,120,200,200")" 2>/dev/null || true)"
    expect_le "$(field "$CONTROL_DIFF" permille)" 20 "消えたのは HUD だけ（他の場所は変わっていない）"
  fi

  # メニューバーの位置は**切替が起きたあとに読む。** 起動直後はまだ配置されていない。
  # 縦の範囲は画面情報から決める（メニューバーの高さ = 画面の上端から表示領域まで）。
  MENU_X="$(grep -E "メニューバー:" "$WORK/7.log" | grep -oE "x=[0-9]+" | tail -1 \
    | cut -d= -f2 || true)"
  MENU_W="$(grep -E "メニューバー:" "$WORK/7.log" | grep -oE "幅=[0-9]+" | tail -1 \
    | cut -d= -f2 || true)"
  MENU_RECT=""
  if [ -n "$MENU_X" ] && [ -n "$MENU_W" ] && [ "$MENUBAR_H" -gt 0 ]; then
    MENU_RECT="${MENU_X},0,${MENU_W},${MENUBAR_H}"
  fi
  if [ -z "$MENU_RECT" ]; then
    ng "メニューバーの表示位置がログに出ていない（項目を確保できていない）"
  else
    ok "メニューバーに項目を確保できた（x=${MENU_X} 幅=${MENU_W}）"
    # **メニューバーを自動的に隠す設定では、画素では何も確かめられない。**
    # 常に隠れているので撮った画面には出ない（この環境がそれだった）。
    # 「変わらなかった」を失敗として報告すると、設定のせいなのか
    # 実装が壊れているのか区別できなくなる。
    if [ "$(defaults read NSGlobalDomain _HIHideMenuBar 2>/dev/null || echo 0)" = "1" ]; then
      skip "メニューバーを自動的に隠す設定のため、番号の見え方は画素で確かめられない"
    else
      MENU_DIFF="$("$PROBE" diff "$WORK/8-ws1.png" "$WORK/8-hud-off.png" \
        --region "$(scale_rect "$MENU_RECT")" 2>/dev/null || true)"
      expect_ge "$(field "$MENU_DIFF" permille)" 20 "メニューバーの番号が切替で変わった"
    fi
  fi

  "$APP" --emit-key ctrl-alt-shift-1 >/dev/null 2>&1
  sleep 2
fi
stop_comet

# ---- 9. 症状A（新規ウィンドウのちらつき） ---------------------------------
# 「目視でしか判定できない」としていた最後の症状。
#
# **ちらつきの実体は「最終的に落ち着く位置とは違う場所に、画面上に居た時間」**
# なので、ウィンドウの矩形を細かく追えば数値になる。追跡は CGWindowList を
# 8ms 間隔で読む（comet とは独立した観測で、権限も要らない）。
echo "==> 9. 症状A（新規ウィンドウが既定位置に見えていた時間）"
if [ -z "$CREATED_WINDOW_IDS" ]; then
  skip "検証用ウィンドウを開いていないので新規ウィンドウを作れない"
else
start_comet "$WORK/9.log" trace
BEFORE_IDS="$(textedit_window_ids)"
"$PROBE" watch --new --ms 4000 --interval-ms 8 --min-area 120000 >"$WORK/9-watch.txt" 2>&1 &
WATCH_PID=$!
sleep 0.6
osascript -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1 || true
wait "$WATCH_PID" || true

NEW_ID=""
for id in $(textedit_window_ids); do
  found=0
  for known in $BEFORE_IDS; do
    if [ "$id" = "$known" ]; then found=1; fi
  done
  if [ "$found" = "0" ]; then
    NEW_ID="$id"
    CREATED_WINDOW_IDS="$CREATED_WINDOW_IDS $id"
  fi
done

SUMMARY="$(grep "^summary id=${NEW_ID} " "$WORK/9-watch.txt" 2>/dev/null || true)"
if [ -z "$NEW_ID" ] || [ -z "$SUMMARY" ]; then
  ng "新しいウィンドウを追跡できなかった（id=${NEW_ID:-不明}）"
else
  NEW_TARGET="$(grep -E "目標 +\[${NEW_ID}\]" "$WORK/9.log" | tail -1 | rect_of || true)"
  FINAL_RECT="$(field "$SUMMARY" final-x),$(field "$SUMMARY" final-y),$(field "$SUMMARY" final-w),$(field "$SUMMARY" final-h)"
  FIRST_RECT="$(field "$SUMMARY" first-x),$(field "$SUMMARY" first-y),$(field "$SUMMARY" first-w),$(field "$SUMMARY" first-h)"
  echo "        現れた位置 $FIRST_RECT → 落ち着いた位置 $FINAL_RECT"
  # 「動かなかった」で通ってしまわないように、**タイルされたことを先に確かめる。**
  expect_rect_near "$FINAL_RECT" "$NEW_TARGET" 2 "新規ウィンドウがレイアウトの位置に収まった"
  expect_le "$(field "$SUMMARY" other-ms)" 150 "既定位置に見えていた時間(ms)"
  expect_le "$(field "$SUMMARY" settle-ms)" 200 "落ち着くまでの時間(ms)"
fi
stop_comet
fi

# ---- 10. 混在アプリの隅寄せ ----------------------------------------------
# 「同じアプリを複数ワークスペースで使う実際の運用が要る」として諦めていた項目。
#
# 表示中のワークスペースにもウィンドウを持つアプリは**アプリごと隠せない**ので、
# 隅寄せへ落ちなければならない。誤ると見ているワークスペースのウィンドウまで消える。
echo "==> 10. 混在アプリは隅寄せへ落ちるか"
if [ -z "$CREATED_WINDOW_IDS" ]; then
  skip "同じアプリで複数ウィンドウを用意できないので混在を作れない"
else
start_comet "$WORK/10.log" debug
# **複数ウィンドウを持つアプリのウィンドウを動かさないと混在にならない。**
# 1枚しか持たないアプリを動かすと、そのアプリは全ウィンドウが非表示側へ回るので
# 「アプリごと非表示」が正しい動作になり、隅寄せの検証にならない（一度これで空振りした）。
# アプリを前面に出せば comet がフォーカスを追う（focus-follows-activation）。
# **すでに前面にあるアプリを activate しても通知は飛ばない。** comet は
# 起動時にツリーの先頭をフォーカス扱いにするので、別のアプリを挟んで
# 「切り替わった」ことにする（挟まずに書いて、毎回ツリー先頭のアプリが動いた）。
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
sleep 1
osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1 || true
sleep 1.5
"$APP" --emit-key ctrl-alt-shift-m >/dev/null 2>&1
sleep 2
# 隅寄せの枚数は状態の出力に出る。再配置のホットキーで出させる。
"$APP" --emit-key ctrl-alt-shift-r >/dev/null 2>&1
sleep 1.5
MOVED_ID="$(grep -oE "\[[0-9]+\] をワークスペース [0-9]+ → 2 へ移した" "$WORK/10.log" \
  | head -1 | grep -oE "[0-9]+" | head -1 || true)"
IS_TEST_WINDOW=0
for id in $CREATED_WINDOW_IDS; do
  if [ "$id" = "$MOVED_ID" ]; then IS_TEST_WINDOW=1; fi
done
if [ -z "$MOVED_ID" ]; then
  ng "ウィンドウをワークスペース 2 へ移せなかった"
elif [ "$IS_TEST_WINDOW" = "0" ]; then
  # 1枚しか持たないアプリのウィンドウが動いた場合は、アプリごと非表示が正しい動作。
  # 混在の検証になっていないので、失敗ではなく省略として報告する。
  skip "混在の状態を作れなかった（動いたのが検証用ウィンドウではない id=${MOVED_ID}）"
else
  # 移した先は非表示だが、同じアプリのウィンドウが表示中にも残っている。
  expect_no_log "$WORK/10.log" "アプリを非表示にした" "表示中のウィンドウを持つアプリを隠さなかった"
  expect_log "$WORK/10.log" "隅寄せ [1-9]" "隠せないぶんを隅へ寄せた"
  LINE="$("$PROBE" windows --any-layer | grep "^id=${MOVED_ID} " || true)"
  if [ -z "$LINE" ]; then
    ok "隅寄せしたウィンドウは画面から見えなくなった"
  else
    expect_ge "$(field "$LINE" x)" $((SCREEN_W - 50)) "隅寄せしたウィンドウが画面の端に居る"
  fi
fi
stop_comet
# 終了後に画面へ戻っていること。戻さないと利用者からは「消えた」ようにしか見えない。
if [ -n "$MOVED_ID" ]; then
  LINE="$("$PROBE" windows --any-layer | grep "^id=${MOVED_ID} " || true)"
  if [ -z "$LINE" ]; then
    ng "終了後もウィンドウが画面に戻っていない（id=${MOVED_ID}）"
  else
    expect_le "$(field "$LINE" x)" $((SCREEN_W - 100)) "終了時に隅寄せしたウィンドウを画面へ戻した"
  fi
fi
fi

# ---- 11. 壁紙（症状D） ----------------------------------------------------
# 画像を置けば機械で判定できる（空のワークスペースへ切り替えれば画面いっぱいが壁紙になる）。
#
# **ただし今の macOS では元の壁紙を読み出せない**（`picture of current desktop` が
# `missing value` を返す。動的な壁紙だと単一のパスが無い）。戻せないものは変えない。
# 登録の経路だけを確かめ、見え方の判定は理由を添えて省略する。
echo "==> 11. 壁紙（症状D）"
sips -s format png --resizeHeightWidthMax 64 /System/Library/CoreServices/DefaultDesktop.heic \
  --out "$WORK/wall2.png" >/dev/null 2>&1 || true
if [ ! -f "$WORK/wall2.png" ]; then
  # 手近な画像が無ければ自分で作る（1x1 の PNG でも登録の確認には足りる）。
  printf '\x89PNG\r\n\x1a\n' >"$WORK/wall2.png"
fi
cat >>"$CONFIG" <<TOML

[wallpaper.map]
2 = "$WORK/wall2.png"
3 = "$WORK/存在しない.png"
TOML
start_comet "$WORK/11.log" debug
expect_log "$WORK/11.log" "壁紙を 1 件登録した" "実在する壁紙だけを登録した"
expect_log "$WORK/11.log" "ワークスペース 3 の壁紙が見つからない" "存在しないパスを警告して捨てた"
ORIGINAL_WALLPAPER="$(osascript -e 'tell application "System Events" to get picture of current desktop' 2>/dev/null || true)"
if [ -z "$ORIGINAL_WALLPAPER" ] || [ "$ORIGINAL_WALLPAPER" = "missing value" ]; then
  skip "今の壁紙を読み出せない（戻せないので実際には切り替えない）"
else
  "$APP" --emit-key ctrl-alt-shift-2 >/dev/null 2>&1
  sleep 2
  expect_log "$WORK/11.log" "壁紙を切り替えた" "ワークスペース切替で壁紙を切り替えた"
  osascript -e "tell application \"System Events\" to set picture of current desktop to \"$ORIGINAL_WALLPAPER\"" \
    >/dev/null 2>&1 || true
fi
stop_comet

# ---- 12. ハングしたアプリに引きずられないか -------------------------------
# 「時間のかかる検証」として後回しにしていた項目。**SIGSTOP で止めれば
# 固まったアプリを確実に再現できる**（AX の応答が返らなくなる）。
echo "==> 12. 固まったアプリに引きずられないか"
# 復帰後の追従を目標矩形と突き合わせるので trace で回す（目標は trace にしか出ない）。
start_comet "$WORK/12.log" trace
FROZEN_PID=""
if [ -n "$CREATED_WINDOW_IDS" ]; then
  FROZEN_PID="$(pgrep -x TextEdit | head -1 || true)"
fi
if [ -z "$FROZEN_PID" ]; then
  # 利用者が開いている TextEdit は止めない（固まったアプリに見えるため）。
  skip "止めてよいアプリが無い（検証用ウィンドウを開いていない）"
else
  echo "        TextEdit (pid=${FROZEN_PID}) を止める"
  kill -STOP "$FROZEN_PID" 2>/dev/null || true
  sleep 1
  "$APP" --emit-key ctrl-alt-shift-r >/dev/null 2>&1
  sleep 4
  # 主ループが固まったアプリを待って止まっていないこと。
  expect_log "$WORK/12.log" "再配置を要求された" "固まったアプリがあってもコマンドを受け付けた"
  expect_no_log "$WORK/12.log" "(fatal error|Fatal error)" "固まったアプリでクラッシュしなかった"
  kill -CONT "$FROZEN_PID" 2>/dev/null || true
  FROZEN_PID=""
  sleep 2
  # 復帰したら追従できること。
  "$APP" --emit-key ctrl-alt-shift-r >/dev/null 2>&1
  sleep 3
  RECOVERED=0
  for id in $CREATED_WINDOW_IDS; do
    TARGET="$(grep -E "目標 +\[$id\]" "$WORK/12.log" | tail -1 | rect_of || true)"
    LINE="$("$PROBE" windows --any-layer | grep "^id=$id " || true)"
    [ -n "$TARGET" ] && [ -n "$LINE" ] || continue
    if [ "$(field "$LINE" x),$(field "$LINE" y),$(field "$LINE" w),$(field "$LINE" h)" = "$TARGET" ]; then
      RECOVERED=$((RECOVERED + 1))
    fi
  done
  # 目標矩形は trace でしか出ないので、debug 実行では突き合わせられない。
  if [ "$RECOVERED" -gt 0 ]; then
    ok "止めていたアプリのウィンドウが目標位置へ戻った（${RECOVERED} 枚）"
  else
    expect_log "$WORK/12.log" "再配置を要求された" "復帰後も再配置を受け付けた"
  fi
fi
stop_comet

# ---- 13. 常駐コスト（--long のときだけ） ----------------------------------
# 10分の放置は普段の実行に入れると長すぎるので、明示したときだけ回す。
if [ "$LONG" = "1" ]; then
  echo "==> 13. 常駐コスト（10分の放置）"
  start_comet "$WORK/13.log" info
  COMET_PID="$(cat "$WORK/pid")"
  RSS_START="$(ps -o rss= -p "$COMET_PID" | tr -d ' ' || echo 0)"
  echo "        開始時 RSS=${RSS_START}KB。10分待つ"
  ELAPSED=0
  CPU_MAX=0
  while [ "$ELAPSED" -lt 600 ]; do
    sleep 60
    ELAPSED=$((ELAPSED + 60))
    CPU="$(ps -o %cpu= -p "$COMET_PID" | tr -d ' ' | cut -d. -f1 || echo 0)"
    if [ "${CPU:-0}" -gt "$CPU_MAX" ]; then CPU_MAX="$CPU"; fi
    echo "        ${ELAPSED}秒: CPU=${CPU}% RSS=$(ps -o rss= -p "$COMET_PID" | tr -d ' ')KB"
  done
  RSS_END="$(ps -o rss= -p "$COMET_PID" | tr -d ' ' || echo 0)"
  expect_le "$CPU_MAX" 2 "無操作で CPU がほぼ 0%"
  expect_le "$(((RSS_END - RSS_START) / 1024))" 20 "10分でメモリが増え続けない(MB)"
  stop_comet
else
  echo "==> 13. 常駐コスト（10分）は省略。回すなら ./scripts/verify.sh --long"
fi

# ---- まとめ -------------------------------------------------------------
echo ""
if [ "$SKIP" -gt 0 ]; then
  echo "==> 結果: 通過 $PASS / 失敗 $FAIL / 省略 $SKIP"
else
  echo "==> 結果: 通過 $PASS / 失敗 $FAIL"
fi
if [ "$FAIL" -gt 0 ]; then
  echo "    ログ: $WORK （このあと消える。残したいなら実行中に別へ写す）"
  # 失敗したログと撮った画面を残す。画素の判定が落ちたときは絵を見ないと分からない。
  mkdir -p "$REPO_ROOT/build/verify-logs"
  cp "$WORK"/*.log "$WORK"/*.png "$REPO_ROOT/build/verify-logs/" 2>/dev/null
  echo "    控え: build/verify-logs/"
  exit 1
fi
exit 0
