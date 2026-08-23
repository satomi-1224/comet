# しくみと制限

[← README](../README.md)


## しくみ

### ディスプレイとワークスペース（i3 の output と同じ考え方）

**1つのディスプレイは常にちょうど1つのワークスペースを映します。**

- 指定したワークスペースが既に別のディスプレイに映っていれば、
  **そのディスプレイへフォーカスを移すだけ**（ウィンドウは動かしません）
- 映っていなければ、**今フォーカスしているディスプレイに映します**。
  そこが映していたワークスペースは非表示になります

2画面で `alt-1` `alt-2` を押したときの動きが i3 と一致します。
ディスプレイを外すと、そこが映していたワークスペースは退避されます。

`[monitors] manage = "main"` にすると、メインディスプレイだけを並べ、
他のディスプレイのウィンドウは素の macOS のまま扱います。

### ワークスペースに macOS の操作スペースを使わない

ネイティブの Spaces は切替に OS のアニメーションが挟まり、外部から制御する公式の API も
ありません。comet は**操作スペースを常に1つだけ使い**、非表示のワークスペースは
アプリごと非表示（`Cmd+H` 相当）にして隠します。

そのアプリのウィンドウが表示中のワークスペースにも残っている場合は、代わりに
画面の外へ追い出します（macOS はウィンドウを完全に画面外へは出させないため、
1pt × 46pt の角だけが残ります）。

### AX の呼び出しは相手アプリごとのキューで行う

Accessibility API の呼び出しは**相手アプリのメインスレッドとの同期 IPC** です。
相手がビジーなら呼び出し側のスレッドが止まります。メインスレッドから呼ぶと、
他人のアプリの都合で comet 全体（ホットキーも描画も）が固まります。

そのため AX 呼び出しはすべてプロセスごとのキューへ逃がし、タイムアウトを短く
設定して「そのアプリだけ諦める」ようにしています。

### レイアウトを強制する

ウィンドウが外部から動かされたら元へ戻します。AX の通知だけでは取りこぼす
（こちらが戻した直後に書き戻されると、以降は通知が来ない）ため、
`CGWindowList` で定期的に実際の矩形を見張ります。AX の往復が要らないので、
ハングしたアプリが混ざっていても止まりません。

どうやっても目標に落ち着かないウィンドウ（文字セル単位でしかリサイズできない端末など）
とは押し合いを続けません。**「この目標にはここまでしか寄らない」と分かった時点の
実測を覚えておき、同じ姿に落ち着いているあいだは触りません。**
目標が変わったときだけ試し直します。

### 入らないときは黙って重ねない

macOS のアプリは指定より小さくなりません（実測: Safari は幅 574、Parsec は 640 が下限）。
最小寸法の合計が領域を超えると、どう配ってもウィンドウが隣にはみ出します。
X11 と違い WM の側では避けようがないので、**何が起きているのかと打つ手を警告に出します。**

```
ws1: 4 枚を並べるには幅が 264pt 足りない（最小寸法の合計 2169pt / 領域 1905pt）。
アプリは指定より小さくならないので**重なる**。内訳: Parsec=640, ターミナル=381, …
1枚をフローティングにする（layout floating tiling）か、
別のワークスペースへ移す（move-node-to-workspace N）と収まる。
```

### Cmd+H は最小化と同じ扱い

利用者がアプリを隠したら、そのウィンドウは**列から外して残りを詰めます**。
外さないと隠れているのに領域だけ確保されて配置に穴が開き、次の再配置では逆に
勝手に表示へ戻されます。表示に戻せば元の場所へ戻ります。

comet 自身が非表示ワークスペースのために隠したぶんとは区別しているので、
ワークスペース切替と混ざりません。

### 並べる対象の見分け方

ダイアログやポップオーバーを掴むとアプリが壊れて見えるので、`AXStandardWindow` の
ウィンドウだけを並べます。加えて**ピクチャーインピクチャのような常に手前へ出る窓**は
AX 上ふつうのウィンドウに見えるため、`kCGWindowLayer`（通常のウィンドウは 0）で除きます。

### 取りこぼしたウィンドウを拾い直す

`AXWindowCreated` は当てになりません。生まれた直後の AX 要素はウィンドウ ID も属性も
返さないことがあり（ブラウザや Electron 製アプリで起きます）、そこで諦めると
そのウィンドウには個別の通知も張られないため**以後どの経路からも拾えません。**

そのため、生成通知は少し待って試し直し、それでも駄目なら `CGWindowList` 側から
「監視しているアプリなのに台帳に無い窓」を定期的に探して走査し直します
（一覧は 0.3ms で取れるので常駐コストはほぼ増えません）。

## 制限

- **入らないときは重なります。** macOS のアプリは指定より小さくならないため、
  最小寸法の合計が領域を超えると避けようがありません（理由と打つ手は警告に出ます）
- `layout accordion`（積み重ね表示）はありません。macOS 側にタブ帯を描く手段が無いためです
- i3 の **scratchpad** と **mark** はありません。scratchpad の代わりに
  ワークスペースを1つ充てる（`move-node-to-workspace 10` と `workspace 10`）、
  mark の代わりに `focus next-window-in-app` を使ってください
- AeroSpace にあって comet に無いコマンド: `macos-native-fullscreen` /
  `macos-native-minimize` / `summon-workspace` / `volume` / `enable` /
  `trigger-binding` / `debug-windows`
  （書いてあっても飛ばし、起動時のログに「未対応」として残します。
  状態の確認は `--query` が受け持ちます）
- 他のタイリングウィンドウマネージャと同時に動かすと、互いの配置を奪い合います
- **`kill -9` で終了すると、退避中のウィンドウが画面外に残ります。**
  `SIGINT` / `SIGTERM` / `SIGHUP`（`kill`・launchd の停止・ログアウト）と
  `ctrl-alt-shift-q` と `exit` は、退避を戻し非表示のアプリを表示へ戻してから終わります

## i3 との対応

| i3 | comet |
|---|---|
| `bindsym $mod+Return exec <terminal>` | `alt-enter = "exec open -a Terminal"` |
| `focus left` / `move left` | 同じ |
| `focus parent` / `focus child` | 同じ |
| `focus output right` | `focus-monitor right`（i3 の綴りも通る） |
| `move container to output right` | `move-node-to-monitor right`（i3 の綴りも通る） |
| `move workspace to output next` | `move-workspace-to-monitor next`（同上） |
| `split h` / `split v` / `split toggle` | 同じ（`split horizontal` などでも可） |
| `layout toggle split` | 同じ（`layout tiles horizontal vertical` でも可） |
| `layout stacking` / `tabbed` | **無し**（macOS 側にタブ帯を描く手段が無い） |
| `fullscreen` | 同じ（ただし macOS のネイティブ全画面ではない） |
| `floating enable` / `disable` / `toggle` | 同じ（`layout floating tiling` でも可） |
| `focus mode_toggle` | 同じ |
| `move position center` | 同じ |
| `move left 10 px` | 同じ（フローティングのときだけ点数が効く） |
| `resize grow` / `shrink width 10 px` | 同じ（`resize width +10` でも可） |
| `kill` | 同じ（`close-window` でも可） |
| `exit` | 同じ（`quit` でも可） |
| `mode "resize"` | `[mode.resize.binding]` + `mode resize` |
| `workspace next` / `prev` / `back_and_forth` | 同じ（`next` / `prev` は空を飛ばす） |
| `workspace_auto_back_and_forth` | `[workspaces] auto-back-and-forth` |
| `focus_follows_mouse` | `[focus] follows-mouse`（**既定は無効**。i3 は有効） |
| `focus_wrapping` | `[focus] wrapping`（**既定は無効**。i3 は有効） |
| `focus floating` / `focus tiling` | 同じ |
| `reload` | 同じ（`reload-config` でも可。**保存すると自動で読み直す**） |
| `gaps inner` / `outer` | `[gaps]` と `gaps inner all set N` コマンド |
| `for_window [criteria] floating enable` | `[[window-rule]]` + `run = "layout floating"` |
| `assign [criteria] → workspace N` | `[[window-rule]]` + `run = "move-node-to-workspace N"` |
| `client.focused` / `client.unfocused` の色 | `[border] color-focused` / `color-unfocused` |
| `i3bar` | `[indicator]`（メニューバーに中身のある番号を並べ、切替時に HUD） |
| `i3-msg <command>` | `comet --send <command>` |
| `i3-msg -t get_workspaces` | `comet --query workspaces` |
| `restart` | **無し**（設定の読み直しは `reload`。入れ替えは終了して起動し直す） |
| `scratchpad` | **無し** |
| `mark` / `[con_mark=…]` | **無し** |
