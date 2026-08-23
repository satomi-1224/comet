# 設定とコマンド

[← README](../README.md)


## 設定ファイル

`~/.config/comet/config.toml`。`--print-default-config` が全項目入りの雛形を出します。
**保存すると自動で読み直します**（ツリーの形とワークスペースの状態は保たれます）。

```toml
[gaps]
inner-horizontal = 3
inner-vertical   = 3
outer-top        = 3
outer-bottom     = 3
outer-left       = 3
outer-right      = 3

[border]
enabled       = true
width         = 2.0
radius        = 10.0
color-focused = "#7aa2f7"

[wallpaper]
dir = "~/Pictures/wallpapers"

[mode.main.binding]
alt-h = "focus left"
alt-l = "focus right"
alt-1 = "workspace 1"
```

**設定の誤りで起動は止まりません。** 解釈できなかった項目は既定値に落ち、
理由が起動時のログに残ります。

| セクション | 主な項目 |
|---|---|
| `[gaps]` | ウィンドウ同士（`inner-*`）と画面の縁（`outer-*`）の間隔 |
| `[border]` | 枠線の有無・幅・角の丸み・色。`color-unfocused` を書くとタイル全部に描く |
| `[indicator]` | ワークスペース番号の出し方（`menubar` / `hud` / `both` / `off`） |
| `[wallpaper]` | ワークスペースごとの壁紙（`dir` かパスの対応表） |
| `[workspaces]` | 個数、非表示の方式、Cmd+Tab で切り替わったときの追従、同じ番号での往復 |
| `[workspaces.names]` | ワークスペースの名前（メニューバーと HUD の表示にだけ使う） |
| `[monitors]` | 並べる対象のディスプレイ（`all` / `main`） |
| `[layout]` | 新しいウィンドウの入り方、ルートの分割方向 |
| `[focus]` | 巡回の並びの寿命と範囲、ポインタへの追従（`follows-mouse`）、端での巻き戻し（`wrapping`） |
| `[performance]` | AX のタイムアウト、適用の間隔、キー連射の速さ |
| `[[window-rule]]` | アプリごとの扱い（浮かせる／置き場所を固定する。i3 の `for_window` と `assign`） |
| `[mode.<名前>.binding]` | キーの層。`main` が既定で、`mode <名前>` で移る |
| `[debug]` | ログの粒度、レイテンシの計測 |

## 既定のキーバインド

既定のキーバインド（すべて設定で変更できます）。

| キー | 動作 |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` | 左・下・上・右のウィンドウへフォーカス |
| `alt-shift-h/j/k/l` | ウィンドウを左・下・上・右へ移動 |
| `alt-ctrl-h/j/k/l` | 分割の境界を動かす（リサイズ・押しっぱなしで連続） |
| `alt-f` / `alt-d` | 次のアプリ / 同じアプリの次のウィンドウへ |
| `alt-e` / `alt-w` | 隣とまとめて新しいコンテナを作る |
| `alt-shift-e` | 分割の比率を均等に戻す |
| `alt-b` / `alt-v` | 次に開くウィンドウを左右／上下に分けて入れる（i3 の `split h` / `split v`） |
| `alt-a` / `alt-shift-a` | コンテナを選ぶ／解除（i3 の `focus parent` / `focus child`） |
| `alt-slash` | 選んでいるコンテナの向きを切り替える |
| `alt-shift-slash` | 入れ子を全部ほどいてルート直下に並べ直す |
| `alt-shift-f` | フローティングとタイルを切り替える |
| `alt-c` | フローティングのウィンドウを画面の中央へ |
| `alt-space` | タイルとフローティングの間でフォーカスを往復（i3 の `focus mode_toggle`） |
| `alt-semicolon` | フォーカス中のウィンドウを領域いっぱいに広げる／戻す |
| `alt-r` | リサイズの層へ入る（`h/j/k/l` で境界を動かし `esc` で戻る） |
| `alt-enter` | ターミナルを開く（`exec open -a Terminal`） |
| `alt-shift-q` | ウィンドウを閉じる |
| `alt-1` … `alt-0` | ワークスペース 1〜10 へ切替 |
| `alt-shift-1` … `alt-shift-0` | ウィンドウを別のワークスペースへ移動して追従 |
| `alt-comma` / `alt-period` | ワークスペースを前／次へ（**空の番号は飛ばす**。端では巻き戻る） |
| `alt-tab` | 直前のワークスペースへ |
| `alt-s` | 次のディスプレイへフォーカスを移す |
| `alt-shift-s` | ウィンドウを次のディスプレイへ移す |
| `alt-ctrl-s` | 今のワークスペースを次のディスプレイへ移す |

フローティングのウィンドウを選んでいるときは、`alt-shift-h/j/k/l` が
**そのウィンドウを点数で動かす**操作に、`alt-ctrl-h/j/k/l` が
**そのウィンドウの寸法を変える**操作に変わります（タイルの列には手を出しません）。

設定とは別に固定のホットキーが3つあります。

| キー | 内容 |
|---|---|
| `ctrl-alt-shift-q` | 終了（退避中のウィンドウを画面へ戻してから終わる） |
| `ctrl-alt-shift-r` | 再配置（全ワークスペースの状態をログに出す） |
| `ctrl-alt-shift-t` | 適用レイテンシをアプリ別に出力（`[debug] timing = true` のとき） |

## 壁紙

ディレクトリを1つ指定すれば、画像を**名前順**にワークスペースへ割り当てます。
足りなければ先頭から繰り返します（3枚なら 1・2・3・1・2・3…）。

```toml
[wallpaper]
dir = "~/Pictures/wallpapers"
```

画像以外のファイルと隠しファイルは数に入れません。
**ディレクトリが無い、または画像が1枚も無いときは壁紙を変えません。**

## コマンド

`[mode.main.binding]` に書けるコマンド。綴りは [AeroSpace](https://github.com/nikitabobko/AeroSpace) 互換です。

| コマンド | 動作 |
|---|---|
| `focus left\|down\|up\|right` | 方向フォーカス |
| `focus parent\|child` | コンテナを選ぶ／解除。以降の `move` / `resize` / `layout` の対象になる |
| `focus next-app\|prev-app` | 次／前のアプリのウィンドウへ（最近使った順） |
| `focus next-window-in-app\|prev-window-in-app` | 同じアプリの次／前のウィンドウへ |
| `focus mode-toggle` | タイルとフローティングの間でフォーカスを往復 |
| `focus floating\|tiling` | 浮いている側／並んでいる側へフォーカスを移す（i3 の綴り） |
| `move left\|down\|up\|right` | ウィンドウ（またはコンテナ）を方向へ移動 |
| `move left 40 px` | **フローティングのウィンドウを点数で動かす**（タイルでは点数を無視） |
| `move position center` | フローティングのウィンドウを画面の中央へ |
| `resize width\|height ±N` | 分割の境界を動かす（フローティングなら自分の寸法） |
| `balance-sizes` | 分割の比率を均等に戻す（入れ子の中まで） |
| `gaps inner\|outer\|top\|bottom\|left\|right set\|plus\|minus N` | 間隔を後から変える（設定は書き換えない） |
| `move-mouse window-lazy-center\|monitor-lazy-center\|…` | マウスポインタを動かす |
| `split horizontal\|vertical\|opposite` | 次に開くウィンドウの入り方を決める |
| `join-with left\|down\|up\|right` | 隣と新しいコンテナを作る |
| `layout tiles horizontal vertical` | コンテナの向きを巡回 |
| `layout floating tiling` | フローティングとタイルを切替 |
| `floating enable\|disable\|toggle` | 同じことを on/off で書く（i3 の綴り） |
| `flatten-workspace-tree` | 入れ子を全部ほどいてルート直下に並べ直す |
| `fullscreen [toggle\|enable\|disable]` | 領域いっぱいに広げる／戻す（引数なしはトグル） |
| `workspace 1..N\|next\|prev\|back-and-forth` | ワークスペース切替 |
| `move-node-to-workspace N\|next\|prev\|back-and-forth` | ウィンドウを別のワークスペースへ |
| `focus-monitor next\|prev\|main\|left\|right` | 別のディスプレイへフォーカスを移す |
| `move-node-to-monitor …` | ウィンドウを別のディスプレイへ |
| `move-workspace-to-monitor …` | 今のワークスペースを別のディスプレイへ（相手のと入れ替わる） |
| `mode <名前>` | キーの層を切り替える |
| `exec <コマンド>` | シェルへ渡して実行する（待たない） |
| `close-window` | ウィンドウを閉じる |
| `reload-config` | 設定を読み直す |
| `exit` | comet を終了する（退避中のウィンドウを戻してから終わる） |

i3 の綴りもそのまま通ります（`kill` / `reload` / `quit` / `split h` / `split v` /
`split toggle` / `layout toggle split` / `focus mode_toggle` / `focus output right` /
`move container to output right` / `move workspace to output next` /
`move container to workspace 3` / `workspace back_and_forth` /
`fullscreen toggle` / `floating toggle` / `resize grow width 50 px` /
`resize shrink height 30 px`）。

`workspace next` / `prev` は**中身のあるワークスペースだけを巡ります**（i3 と同じ）。
空の番号へは `workspace N` で直に行きます。`move-node-to-workspace next` / `prev` は
番号順のままで、空いている番号へウィンドウを出せます。

`fullscreen` は **macOS のネイティブフルスクリーンではありません**。
あれは専用の操作スペースを作るためワークスペースの実装と衝突します。
タイル配置の中で1枚だけ広げ、後ろのウィンドウは配置を保ったまま覆います。

## コマンドラインオプション

| オプション | 内容 |
|---|---|
| `--config <path>` | 設定ファイルの場所（既定 `~/.config/comet/config.toml`） |
| `--no-config` | 設定を読まず組み込みの既定で起動する |
| `--print-default-config` | 既定設定を出力して終了（雛形になる） |
| `--log-level <level>` | `trace` / `debug` / `info` / `warn` / `error` / `off` |
| `--preview-layout <n>` | n 枚のときの配置を図示して終了。**ウィンドウには触れない** |
| `--dry-run` | 配置を計算するがウィンドウは動かさない |
| `--print-keys` | 指定できるキー名の一覧 |
| `--send <command>` | 常駐している comet へコマンドを送る（i3 の `i3-msg`） |
| `--query <topic>` | 状態を問い合わせる（`workspaces` / `windows` / `monitors` / `tree` / `state`） |
| `--help` | ヘルプ |

## 外から動かす（i3 の `i3-msg` 相当）

常駐している comet へ UNIX ドメインソケット経由でコマンドを送れます。
**設定に書ける綴りがそのまま使えます。**

> [!NOTE]
> `comet` を PATH に置く方法。Nix のモジュールを使っているなら**そのまま使えます**
> （本体とは別に `bin/comet` だけを PATH へ入れています）。そうでなければ
> バンドルの中を指す symlink を張ってください。
>
> ```bash
> ln -s ~/Applications/comet.app/Contents/MacOS/comet ~/.local/bin/comet
> ```

```bash
comet --send "workspace 3"
comet --send "move-node-to-monitor next"
comet --send "gaps inner all set 20"
```

状態は1行1件の `key=value` で返るので、状態バーからそのまま読めます。

```console
$ comet --query workspaces
ws=1 state=focused monitor=1 windows=3
ws=2 state=visible monitor=2 windows=1
ws=5 state=hidden windows=2

$ comet --query monitors
monitor=1 x=0 y=0 w=1920 h=1080 primary=yes ws=1 focused=yes
monitor=2 x=1920 y=0 w=1920 h=1080 primary=no ws=2 focused=no
```

解釈できないコマンドは**終了コード 1** と理由を返します
（「効かなかった」のか「そんなコマンドは無い」のかがスクリプトから区別できます）。
ソケットは `~/Library/Caches/local.comet/comet.sock` に 0600 で作り、終了時に消します。
