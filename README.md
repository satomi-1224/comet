# comet

macOS 向けのタイリングウィンドウマネージャ。AeroSpace + Hammerspoon の2プロセス構成を、
Swift 製の単一プロセスに置き換えることを目的とする。

設計の全体像・性能問題の分析・実装フェーズは [DESIGN.md](DESIGN.md) を参照。

## 現在の状態

**Phase 6（常用化）まで実装済み。潰すべき4症状はすべて実測で解消を確認した。**

- ウィンドウを開くと自動でタイルされ、閉じると再配置される
- `focus` / `move` / `resize` / `join-with` / `layout` が動く
- ワークスペース 10 個。`alt-1`..`alt-0` で切替、`alt-shift-1`..で移動して追従、`alt-tab` で直前へ
- 設定ファイル（`~/.config/comet/config.toml`）でギャップ・キーバインド・ウィンドウルールを変えられる
- 寸法を無視するアプリは自動でフローティングへ降格する
- `[debug] timing = true` + `ctrl-alt-shift-t` でアプリ別の適用レイテンシが出る
- フォーカス枠線・ワークスペースインジケータ（メニューバー + HUD）・壁紙切替
- 設定は**保存すると自動で読み直す**（ツリーの形は保たれる）
- ログイン起動（`start-at-login = true`）

置き換えの動機だった4症状は、`./scripts/verify.sh` で機械的に判定している。

| | 症状 | 実測 |
|---|---|---|
| A | 新規ウィンドウがデフォルト位置に一瞬出てから飛ぶ | 既定位置に居るのは **14〜24ms**（1〜1.5フレーム） |
| B | リサイズ連打で追従しない・飛ぶ・戻る | 押しっぱなしで約 **30Hz** 追従 |
| C | ワークスペース切替が遅い・ちらつく | 切替後に最初に撮れた1枚（**~60〜110ms**）で前のウィンドウが残っていない |
| D | 壁紙変更がワンテンポ遅れる | 同じ1枚で既に新しい壁紙（旧構成は **0.2〜1.5 秒**） |

進捗の詳細は [PROGRESS.md](PROGRESS.md)。

## 必要なもの

- macOS 14 以降（開発環境は 26.5.2 で検証）
- Swift 6.0 以降（Command Line Tools のみで可。Xcode は不要）

Xcode を入れていない場合、SPM は `Testing.framework` を自動では見つけられない。
`scripts/env.sh` が探索パスと rpath を補うので、テストは `swift test` ではなく
`./scripts/test.sh` を使うこと。

## 使い方

```bash
# 単体テスト
./scripts/test.sh

# 実機検証（AeroSpace を止めて実際に動かし、終わったら戻す）
./scripts/verify.sh

# 常駐コストの10分放置まで含める
./scripts/verify.sh --long

# .app を組み立てる（アクセシビリティ権限に必要）
./scripts/build-app.sh release

# 前景で起動。ログが端末に出る。終了は Ctrl-C か ctrl-alt-shift-q
build/comet.app/Contents/MacOS/comet --log-level debug

# 常駐起動。ログは統一ログへ
open build/comet.app
log stream --predicate 'subsystem == "local.comet"'
```

### 検証の道具（`comet-probe`）

`verify.sh` から呼ぶ検証専用の実行ファイル。**「目視でしか判定できない」項目を
機械に判定させる**ために、撮った画面の画素とウィンドウの実座標を読む。

```bash
screencapture -x /tmp/screen.png

# 枠線が目標の矩形に描かれているか（四辺に色が乗っている割合）
.build/debug/comet-probe edges /tmp/screen.png '#ff00ff' --rect 6,62,1274,1596 --inset 14

# 画面に出ているウィンドウの実座標（アクセシビリティ権限は要らない）
.build/debug/comet-probe windows

# 新しく現れたウィンドウが落ち着くまでを追う（症状A の計測）
.build/debug/comet-probe watch --new --ms 4000
```

撮影そのものは `screencapture` に任せている。**画面収録の権限を comet 側に
要求しないため**で、端末が既に持っている権限で撮った PNG を読むだけにしてある。

### コマンド

設定の `[mode.main.binding]` に書ける。綴りは AeroSpace 互換。

| コマンド | 動作 |
|---|---|
| `focus left\|down\|up\|right` | 方向フォーカス |
| `move left\|down\|up\|right` | ウィンドウを方向へ移動 |
| `resize width\|height ±N` | 分割の境界を動かす |
| `join-with left\|down\|up\|right` | 隣と新しいコンテナを作る |
| `layout tiles horizontal vertical` | 親コンテナの向きを巡回 |
| `layout floating tiling` | フローティングとタイルを切替 |
| `workspace 1..N\|back-and-forth` | ワークスペース切替 |
| `move-node-to-workspace N` | ウィンドウを別のワークスペースへ |
| `close-window` | ウィンドウを閉じる |
| `reload-config` | 設定を読み直す |
| `fullscreen` | フォーカス中のウィンドウを領域いっぱいに広げる／戻す（トグル） |
| `focus next-app\|prev-app` | 次／前のアプリのウィンドウへ（最近使った順） |
| `focus next-window-in-app\|prev-window-in-app` | 同じアプリの次／前のウィンドウへ |

`fullscreen` は**macOS のネイティブフルスクリーンではない**。あれは専用の操作スペースを
作るためワークスペースの実装と衝突する。タイル配置の中で1枚だけ広げ、後ろのウィンドウは
配置を保ったまま覆う（もう一度押すと元に戻る）。

未対応: `move-node-to-monitor` / `focus-monitor` / `move-workspace-to-monitor`
（**2台目のモニタが無いと検証できない**）、`mode`（モーダルなキー層）、
`flatten-workspace-tree`。書いてあっても起動時に飛ばされる。

### オプション

| オプション | 内容 |
|---|---|
| `--log-level <level>` | `trace` / `debug` / `info` / `warn` / `error` / `off`。既定は設定ファイルの値、無ければ `info` |
| `--config <path>` | 設定ファイルの場所。既定は `~/.config/comet/config.toml` |
| `--no-config` | 設定ファイルを読まず組み込みの既定で起動する |
| `--print-default-config` | 組み込みの既定設定を出力して終了。設定ファイルの雛形になる |
| `--preview-layout <n>` | n 枚のときの配置を図示して終了。**ウィンドウには一切触れない** |
| `--dry-run` | 配置を計算するがウィンドウは動かさない。他の WM が動いている環境での検証用 |
| `--run <command>` | 起動後にコマンドを実行する。複数回指定可。ホットキーを押せない環境での検証用 |
| `--emit-key <spec[:n]>` | 合成キーを送って終了する。n を 2 以上にすると押しっぱなしを再現する（検証用） |
| `--emit-drag <x,y:dx,dy>` | 合成ドラッグを送って終了する（検証用） |
| `--hotkey <spec>` | 押下をログに出すだけの確認用ホットキー。複数回指定可 |
| `--print-keys` | 指定できるキー名を一覧表示 |
| `--help` | ヘルプ |

常駐中のホットキー（設定とは別に固定）:

| キー | 内容 |
|---|---|
| `ctrl-alt-shift-q` | 終了 |
| `ctrl-alt-shift-r` | 再配置（全ワークスペースの状態をログに出す） |
| `ctrl-alt-shift-t` | 適用レイテンシの出力（`[debug] timing = true` のとき） |

ホットキーの書式は `alt-shift-h` のように修飾キーとキーをハイフンで連ねる。
修飾キーは `cmd` / `alt` / `ctrl` / `shift`（別名 `command` / `opt` / `option` / `control`）。
`-` 自体をキーに指定するときは `minus` と綴る。

## 設定

```bash
# 雛形を書き出す
mkdir -p ~/.config/comet
comet --print-default-config > ~/.config/comet/config.toml
```

既定のキーバインドは現行 AeroSpace 設定の移植で、`alt-hjkl`（フォーカス）/
`alt-shift-hjkl`（移動）/ `alt-ctrl-hjkl`（リサイズ）/ `alt-e`・`alt-w`（まとめる）/
`alt-slash`（向きの切替）/ `alt-shift-f`（フローティング切替）/
`alt-1`..`alt-0`（ワークスペース切替）/ `alt-shift-1`..（移動して追従）/ `alt-tab`（直前へ）。

**設定の誤りで起動は止まらない。** 解釈できなかった項目は既定値に落ち、
理由が起動時のログに出る。

新しいウィンドウの入り方は 2 通りから選べる。

| `[layout] insertion` | 動き |
|---|---|
| `split`（既定） | フォーカス中のウィンドウの領域を分割して入る（dwindle） |
| `sibling` | フォーカス中のウィンドウの隣に並べる（AeroSpace と同じ） |

`--preview-layout <n>` で、ウィンドウに触れずに枚数ごとの配置を確認できる。

### アプリ・ウィンドウの巡回

既定では `alt-f` が次のアプリ、`alt-d` が同じアプリの次のウィンドウ（Hammerspoon から移植）。

| 設定 | 内容 |
|---|---|
| `[focus] cycle-reset-ms` | 続けて押したときに**同じ並びを使い続ける**時間。既定 1500。0 にすると毎回組み直す |
| `[focus] cycle-scope` | `workspace`（既定・表示中のワークスペースだけ）/ `all`（全ワークスペース。行き先へ自動で切り替わる） |

アプリの並びは**最近使った順**で、各アプリの代表はそのアプリで最後に見ていたウィンドウ。
`cycle-reset-ms` の間は並びを組み直さないので、押し続けると3つ目・4つ目へ進める
（毎回組み直すと2つのアプリを往復するだけになる）。

同じアプリ内の巡回は id の昇順の固定の輪なので、3枚以上あっても順に回れる。

### 見た目

| 設定 | 内容 |
|---|---|
| `[border]` | フォーカス中のウィンドウに重ねる枠線。線の幅だけ外側に広がるのでギャップの中に収まる |
| `[indicator]` | ワークスペース番号。`menubar` / `hud` / `both` / `off` |
| `[wallpaper] dir` | 画像を入れたディレクトリ。**これだけ書けば済む** |
| `[wallpaper.map]` | ワークスペース番号 → 画像パス。`dir` より優先する |

```toml
[wallpaper]
dir = "~/Pictures/wallpapers"
```

ディレクトリの画像を**名前順**（Finder と同じ並びなので `2.png` が `10.png` より前）に
ワークスペースの数まで取り、**足りなければ先頭から繰り返す**。
3枚をワークスペース10個に割り当てると 1・2・3・1・2・3・1・2・3・1 になる。

- 画像以外のファイル（`.DS_Store` やメモ）と隠しファイルは数に入れない
- **ディレクトリが無い / 画像が1枚も無いときは壁紙を変えない**
- 個別に差し替えたいワークスペースだけ `[wallpaper.map]` に書く

壁紙のパスは起動時に実在を確認し、無いものは警告して捨てる。

### ワークスペース

macOS ネイティブの Spaces は常に1つだけ使い、非表示のワークスペースは
**アプリごと非表示にする**（`Cmd+H` 相当）ことで隠す。切替に OS のアニメーションが挟まらない。

| `[workspaces] hidden` | 動き |
|---|---|
| `hide-app`（既定） | アプリごと非表示。**完全に消え、Mission Control にも出ない** |
| `off-screen` | 画面の隅へ追い込む。**1pt × 46pt の角が残る**（macOS はウィンドウを画面外へ出させない） |

`hide-app` は粒度がアプリ単位なので、**そのアプリの全ウィンドウが非表示ワークスペースに
あるときだけ**使える。表示中のワークスペースにもウィンドウを持つアプリ（Chrome を
ws1 と ws2 で使うなど）は自動的に隅寄せへ落ちる。

**Cmd+Tab には非表示アプリも出る。** そこから選ぶとアプリごと表示に戻り、
そのウィンドウのワークスペースへ自動で切り替わる（`focus-follows-activation`）。

`ctrl-alt-shift-q` で終了すると、退避していたウィンドウは画面へ戻してから終わる。
`kill` で落とすと画面外に残るので注意。

### 複数ディスプレイ

**制御するのはメインディスプレイ（メニューバーがある画面）だけ。**
サブディスプレイへ置いたウィンドウは管理対象から外れ、**素の macOS と同じように
自由に動かせる・大きさも変えられる**。タイルの対象にもならず、ワークスペースを
切り替えても消えない。

- ウィンドウの**中心が乗っている画面**でどちらのものかを決める
- メインからサブへドラッグすると、その時点で管理から外れる（引き戻さない）
- サブからメインへ戻すと、再びタイル配置に入る
- サブにウィンドウを持つアプリは**アプリごと非表示にしない**
  （`Cmd+H` 相当はアプリの全ウィンドウを消すため、サブ側まで消えてしまう）

以下のシステム設定が前提になる。

| 設定 | 値 |
|---|---|
| Mission Control > ディスプレイごとに個別の操作スペース | オフ |
| Mission Control > 最新の使用状況に基づいて操作スペースを自動的に並べ替える | オフ |
| Stage Manager | オフ |
| アクセシビリティ > 視差効果を減らす | オン推奨 |

## セットアップ

```bash
# 1. 署名 ID を作る（一度だけ。下の「1.」参照）
./scripts/make-signing-cert.sh

# 2. .app を組み立てる
./scripts/build-app.sh release

# 3. 設定の雛形を置く
mkdir -p ~/.config/comet
./build/comet.app/Contents/MacOS/comet --print-default-config > ~/.config/comet/config.toml

# 4. macOS のシステム設定を合わせる（下の「3.」参照）

# 5. AeroSpace を止める
osascript -e 'quit app "AeroSpace"'

# 6. 前景で起動して様子を見る
./build/comet.app/Contents/MacOS/comet --log-level debug

# 7. 問題なければ常駐に切り替え、設定に start-at-login = true を書く
open build/comet.app
```

### 1. 署名 ID を作る（推奨・一度だけ）

アクセシビリティ権限はコード署名の同一性に紐づく。ad-hoc 署名はビルドのたびに
ハッシュが変わるため、**再ビルドすると権限が外れて再許可を求められる**。

```bash
./scripts/make-signing-cert.sh
```

キーチェーンのパスワード入力を求められる。初回の `codesign` で出るアクセス許可は
「常に許可」を選ぶこと。

### 2. アクセシビリティ権限を与える

`build/comet.app` を初回起動するとダイアログが出る。出ない場合は
システム設定 > プライバシーとセキュリティ > アクセシビリティ で `comet` を有効にする。

権限が外れたときのリセット:

```bash
tccutil reset Accessibility local.comet
```

### 3. 必須のシステム設定

画面外退避方式（ワークスペース）はネイティブ Space が1つであることを前提にしている。
以下が合っていないと配置が崩れる。

| 設定 | 値 | 理由 |
|---|---|---|
| Mission Control > ディスプレイごとに個別の操作スペース | **オフ** | ネイティブ Space を1つに保つ |
| Mission Control > 最新の使用状況に基づいて操作スペースを自動的に並べ替える | **オフ** | 順序が動くと座標系の前提が崩れる |
| Stage Manager | **オフ** | ウィンドウ配置を横取りする |
| アクセシビリティ > 視差効果を減らす | **オン推奨** | ウィンドウ移動時の OS アニメーションを抑える |

**緑ボタンのフルスクリーンは使わない。** 独自の Space を作るため画面外退避と衝突する。
フルスクリーン化されたウィンドウは管理対象から外れる。

### 4. 移行時に消すもの

| 対象 | 理由 |
|---|---|
| AeroSpace | ホットキーとウィンドウ配置を奪い合う |
| `~/.config/aerospace/wallpaper.sh` の呼び出し | 壁紙は comet の `[wallpaper] dir` に移した |
| Hammerspoon の「修飾キー + BS でウィンドウを閉じる」 | comet の `close-window` と重複する |
| Hammerspoon の `modules/app_switcher.lua`（`alt-f` / `alt-d`） | comet の `focus next-app` / `focus next-window-in-app` に移した。**両方動くとキーを奪い合う**ので `init.lua` の `require("modules.app_switcher")` を外す |

Hammerspoon の `app_switcher.lua` / `clipboard.lua` / `search.lua` /
`command_launcher*.lua` / `snippets*.lua` はそのまま残してよい。

## 開発上の注意

### AeroSpace と同時に動かさない

両方が動くと互いのウィンドウ配置を上書きし合って発振する。
また `alt-*` 系のホットキーは先に登録した側が勝つ。開発中は AeroSpace を止めること。

```bash
osascript -e 'quit app "AeroSpace"'
```

### 二重起動はロックで弾かれる

`~/Library/Caches/local.comet/comet.lock` を `flock(2)` で保持する。
2つ目のインスタンスは権限確認より前に停止する。

### メインスレッドで同期 AX 呼び出しをしない

本プロジェクトの最重要の設計制約。AX 呼び出しは対象アプリの都合で
最大6秒ブロックしうるため、メインスレッドで呼ぶと WM 全体が固まる。
AX へのアクセスは `CometAccessibility` の `ApplierPool` が返す PID ごとのキュー上でのみ行う。
詳細は [DESIGN.md §4.2](DESIGN.md)。

## 構成

```
Sources/
  CometSupport/         ログ、起動オプション、インスタンスロック
  CometInput/           ホットキー（Carbon RegisterEventHotKey）
  CometAccessibility/   AX API へのアクセス層、PID ごとのキュー、権限
  CometCore/            状態機械とレイアウト（副作用のない計算はここ）
    State/              BSP ツリー、正規化、ワークスペース、台帳、モニタ、ウィンドウルール
    Layout/             矩形の算出、座標変換、丸め
    Commands/           コマンドのパースとツリー操作
  CometDecoration/      内蔵UI（枠線・インジケータ・壁紙）
  CometConfig/          設定ファイル（TOML）の読み込み
  comet/                エントリポイント
scripts/
  env.sh             共通ビルド環境（CLT 向けの探索パス補正）
  test.sh            テスト実行
  build-app.sh       .app の組み立てと署名
  make-signing-cert.sh  開発用署名 ID の作成
```

## 権限が外れたときの見分け方

ウィンドウが1枚も並ばないときは、起動時のログに理由が出る。

```
WRN ウィンドウを1枚も認識できなかった（ID 取得に 5 件失敗: 引数が不正（権限が外れている疑い…
```

ad-hoc 署名の identifier には実行ファイルの内容ハッシュが入るため、
**再ビルドすると別アプリとして扱われて権限が外れる。**
`./scripts/make-signing-cert.sh` で固定の署名 ID を作れば維持される。
