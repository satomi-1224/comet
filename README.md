<p align="center">
  <img src="docs/icon.png" width="128" alt="comet">
</p>

<h1 align="center">comet</h1>

<p align="center">
  <b>macOS 向けのタイリングウィンドウマネージャ</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" alt="platform">
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="license">
</p>

BSP ツリーでウィンドウを自動的に並べ、キーボードだけで操作できるようにします。
ワークスペース・フォーカス枠線・ワークスペースごとの壁紙まで**1つのプロセス**で完結し、
補助のスクリプトランタイムを必要としません。

```
┌──────────────────┬──────────────────┐
│                  │                  │
│                  │     Terminal     │
│     Browser      ├──────────────────┤
│                  │                  │
│                  │      Editor      │
└──────────────────┴──────────────────┘
   alt-h/j/k/l でフォーカス、alt-shift-… で移動、alt-1..0 でワークスペース
```

## 特長

- **開いたら並ぶ** — ウィンドウを開くと自動でタイルされ、閉じると残りが詰まる
- **キーボード操作** — フォーカス・移動・リサイズ・分割方向の切替・フローティング切替
- **ワークスペース 10 個** — macOS の操作スペースを使わないので**切替にアニメーションが挟まらない**
- **レイアウトを強制する** — 掴んで動かされても、外部から座標を書き換えられても元へ戻す
- **メインディスプレイだけを制御** — サブディスプレイは素の macOS のまま自由に使える
- **内蔵の見た目** — フォーカス枠線、ワークスペース番号（メニューバー / HUD）、
  ワークスペースごとの壁紙
- **設定は TOML 1枚** — 保存すると自動で読み直す（ツリーの形は保たれる）
- **単一プロセス** — 常駐は comet だけ。CPU はほぼ 0%、メモリは 40MB 前後

## 動作要件

- macOS 14 以降
- Swift 6 ツールチェイン（Xcode は不要。Command Line Tools だけで組める）
- アクセシビリティ権限

## インストール

```bash
git clone https://github.com/satomi-1224/comet.git
cd comet

# 1. 署名 ID を作る（一度だけ。省略すると入れ替えのたびに権限を求められる）
./scripts/make-signing-cert.sh

# 2. .app を組み立てて ~/Applications へ入れる
./scripts/install-app.sh release

# 3. 設定の雛形を置く
mkdir -p ~/.config/comet
./build/comet.app/Contents/MacOS/comet --print-default-config > ~/.config/comet/config.toml
```

初回起動時に**アクセシビリティ権限**を求められます。
「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で許可してください。

> [!IMPORTANT]
> **アクセシビリティ権限はコード署名の同一性に紐づきます。** ad-hoc 署名のままだと
> 内容が変わるたびにハッシュが変わり、入れ替えるたびに許可を求められます。
> `make-signing-cert.sh` で固定の署名 ID を作っておくと出なくなります。

### 必要なシステム設定

| 設定 | 値 | 理由 |
|---|---|---|
| Mission Control > ディスプレイごとに個別の操作スペース | オフ | 操作スペースが分かれるとワークスペースの管理と衝突する |
| Mission Control > 最新の使用状況に基づいて操作スペースを自動的に並べ替える | オフ | 並び順が動くと切替先が定まらない |
| Stage Manager | オフ | ウィンドウの位置を横取りされる |
| アクセシビリティ > 視差効果を減らす | オン（推奨） | 切替が速く見える |

### Nix（home-manager）で使う

設定と自動起動を宣言的に持てます。flake を input に足して、home-manager の
モジュールを読み込みます。

```nix
{
  inputs.comet.url = "github:satomi-1224/comet";

  # home-manager の設定
  imports = [ inputs.comet.homeManagerModules.default ];

  programs.comet = {
    enable = true;
    settings = {
      gaps = { inner-horizontal = 7; inner-vertical = 7; };
      border.color-focused = "#7aa2f7";
      wallpaper.dir = "~/Pictures/wallpapers";
      mode.main.binding = {
        alt-h = "focus left";
        alt-l = "focus right";
        alt-1 = "workspace 1";
      };
    };
  };
}
```

| オプション | 既定 | 内容 |
|---|---|---|
| `enable` | `false` | 有効にする |
| `settings` | `{}` | `config.toml` の内容（TOML へ変換して置く） |
| `settingsFile` | `null` | 書いてある `config.toml` をそのまま置く。`settings` より優先 |
| `app` | `~/Applications/comet.app` | 本体の場所 |
| `startService` | `true` | launchd agent として登録し、ログイン時に起動する |
| `logFile` | `~/Library/Logs/comet.log` | launchd から起動したときのログ |

**キーバインドは置き換えです**（既定へ追加されるのではありません）。書くなら必要なものを
全部書いてください。設定は保存を検知して自動で読み直すので、switch すればそのまま反映されます。

> [!IMPORTANT]
> **本体は Nix ストアに置きません。** 理由は2つあります。
> 1. comet は Swift 6 を要求しますが、nixpkgs の Swift は 5.10 でストアの中では組めません
> 2. アクセシビリティ権限はアプリの同一性に紐づくため、更新のたびにパスが変わる
>    ストアへ置くと権限が毎回外れます
>
> 本体は `./scripts/install-app.sh` が `~/Applications/comet.app` へ入れます。
> モジュールが受け持つのは**設定・自動起動・ログの置き場所**です。

### ログイン時に起動する

設定に `start-at-login = true` を書くか、launchd へ登録します。

```bash
open ~/Applications/comet.app     # 常駐起動（終了は ctrl-alt-shift-q）
```

## 使い方

既定のキーバインド（すべて設定で変更できます）。

| キー | 動作 |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` | 左・下・上・右のウィンドウへフォーカス |
| `alt-shift-h/j/k/l` | ウィンドウを左・下・上・右へ移動 |
| `alt-ctrl-h/j/k/l` | 分割の境界を動かす（リサイズ・押しっぱなしで連続） |
| `alt-f` / `alt-d` | 次のアプリ / 同じアプリの次のウィンドウへ |
| `alt-e` / `alt-w` | 隣とまとめて新しいコンテナを作る |
| `alt-slash` | 親コンテナの向きを切り替える |
| `alt-shift-f` | フローティングとタイルを切り替える |
| `alt-semicolon` | フォーカス中のウィンドウを領域いっぱいに広げる／戻す |
| `alt-1` … `alt-0` | ワークスペース 1〜10 へ切替 |
| `alt-shift-1` … `alt-shift-0` | ウィンドウを別のワークスペースへ移動して追従 |
| `alt-tab` | 直前のワークスペースへ |

設定とは別に固定のホットキーが3つあります。

| キー | 内容 |
|---|---|
| `ctrl-alt-shift-q` | 終了（退避中のウィンドウを画面へ戻してから終わる） |
| `ctrl-alt-shift-r` | 再配置（全ワークスペースの状態をログに出す） |
| `ctrl-alt-shift-t` | 適用レイテンシをアプリ別に出力（`[debug] timing = true` のとき） |

## 設定

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
| `[border]` | フォーカス枠線の有無・幅・角の丸み・色 |
| `[indicator]` | ワークスペース番号の出し方（`menubar` / `hud` / `both` / `off`） |
| `[wallpaper]` | ワークスペースごとの壁紙（`dir` かパスの対応表） |
| `[workspaces]` | 個数、非表示の方式、Cmd+Tab で切り替わったときの追従 |
| `[layout]` | 新しいウィンドウの入り方、ルートの分割方向 |
| `[focus]` | アプリ・ウィンドウ巡回の並びの寿命と範囲 |
| `[performance]` | AX のタイムアウト、適用の間隔、キー連射の速さ |
| `[[window-rule]]` | アプリごとの扱い（`layout floating` など） |
| `[debug]` | ログの粒度、レイテンシの計測 |

### 壁紙

ディレクトリを1つ指定すれば、画像を**名前順**にワークスペースへ割り当てます。
足りなければ先頭から繰り返します（3枚なら 1・2・3・1・2・3…）。

```toml
[wallpaper]
dir = "~/Pictures/wallpapers"
```

画像以外のファイルと隠しファイルは数に入れません。
**ディレクトリが無い、または画像が1枚も無いときは壁紙を変えません。**

### コマンド

`[mode.main.binding]` に書けるコマンド。綴りは [AeroSpace](https://github.com/nikitabobko/AeroSpace) 互換です。

| コマンド | 動作 |
|---|---|
| `focus left\|down\|up\|right` | 方向フォーカス |
| `focus next-app\|prev-app` | 次／前のアプリのウィンドウへ（最近使った順） |
| `focus next-window-in-app\|prev-window-in-app` | 同じアプリの次／前のウィンドウへ |
| `move left\|down\|up\|right` | ウィンドウを方向へ移動 |
| `resize width\|height ±N` | 分割の境界を動かす |
| `join-with left\|down\|up\|right` | 隣と新しいコンテナを作る |
| `layout tiles horizontal vertical` | 親コンテナの向きを巡回 |
| `layout floating tiling` | フローティングとタイルを切替 |
| `fullscreen` | 領域いっぱいに広げる／戻す（トグル） |
| `workspace 1..N\|back-and-forth` | ワークスペース切替 |
| `move-node-to-workspace N` | ウィンドウを別のワークスペースへ |
| `close-window` | ウィンドウを閉じる |
| `reload-config` | 設定を読み直す |

`fullscreen` は **macOS のネイティブフルスクリーンではありません**。
あれは専用の操作スペースを作るためワークスペースの実装と衝突します。
タイル配置の中で1枚だけ広げ、後ろのウィンドウは配置を保ったまま覆います。

### コマンドラインオプション

| オプション | 内容 |
|---|---|
| `--config <path>` | 設定ファイルの場所（既定 `~/.config/comet/config.toml`） |
| `--no-config` | 設定を読まず組み込みの既定で起動する |
| `--print-default-config` | 既定設定を出力して終了（雛形になる） |
| `--log-level <level>` | `trace` / `debug` / `info` / `warn` / `error` / `off` |
| `--preview-layout <n>` | n 枚のときの配置を図示して終了。**ウィンドウには触れない** |
| `--dry-run` | 配置を計算するがウィンドウは動かさない |
| `--print-keys` | 指定できるキー名の一覧 |
| `--help` | ヘルプ |

## しくみ

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
とは押し合いを続けず、数回で一旦諦めてしばらく待ちます。

### 並べる対象の見分け方

ダイアログやポップオーバーを掴むとアプリが壊れて見えるので、`AXStandardWindow` の
ウィンドウだけを並べます。加えて**ピクチャーインピクチャのような常に手前へ出る窓**は
AX 上ふつうのウィンドウに見えるため、`kCGWindowLayer`（通常のウィンドウは 0）で除きます。

## 開発

```bash
swift build                 # ビルド
./scripts/test.sh           # 単体テスト（576 件）
./scripts/verify.sh         # 実機検証（実際にウィンドウを動かして画素と座標で判定）
./scripts/build-app.sh      # .app を組み立てる
```

> [!NOTE]
> Xcode を入れていない環境では `swift test` が Foundation の解決に失敗します。
> `./scripts/test.sh` が必要な設定を渡すので、テストはこちらから実行してください。

`scripts/verify.sh` は実際にウィンドウを開き、合成キー・合成ドラッグを送り、
画面を撮って画素で判定します（枠線が描かれているか、壁紙が切り替わったか、
掴んで動かしたウィンドウが戻るか、Mission Control 中に枠線が消えるか、など）。
`comet-probe` が撮った画面とウィンドウの実座標を読む道具です。

```
Sources/
  comet/             実行ファイル。起動・配線・ホットキー登録
  comet-probe/       検証用の観測ツール
  CometCore/         ツリー、レイアウト、ワークスペース、適用スケジューラ
  CometAccessibility AX の呼び出しと通知（プロセスごとのキュー）
  CometConfig/       TOML の読み込みと監視
  CometInput/        ホットキーと合成イベント
  CometDecoration/   枠線・インジケータ・壁紙
  CometSupport/      ログ、起動オプション、多重起動の防止
  CometProbe/        画素と矩形の判定
```

## 制限

- **メインディスプレイだけを制御します。** サブディスプレイのウィンドウは
  管理対象外で、素の macOS と同じように扱えます
- 未対応のコマンド: `move-node-to-monitor` / `focus-monitor` /
  `move-workspace-to-monitor` / `mode`（モーダルなキー層）/ `flatten-workspace-tree`
- 他のタイリングウィンドウマネージャと同時に動かすと、互いの配置を奪い合います
- `kill` で終了すると、退避中のウィンドウが画面外に残ります
  （`ctrl-alt-shift-q` で終了してください）

## ライセンス

[MIT](LICENSE)

## 謝辞

設定とコマンドの綴りは [AeroSpace](https://github.com/nikitabobko/AeroSpace) を参考にしています。
