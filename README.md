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
**操作の語彙は i3 に合わせてあり**、ワークスペース・複数ディスプレイ・キーの層（`mode`）・
フォーカス枠線・ワークスペースごとの壁紙まで**1つのプロセス**で完結します。
補助のスクリプトランタイムは要りません。

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
- **複数ディスプレイ** — i3 の output と同じ考え方。1台につき1つのワークスペースを映し、
  ウィンドウもワークスペースもディスプレイ間で動かせる（メインだけに絞ることもできる）
- **キーの層** — i3 の `mode "resize"` 相当。層の中では修飾キーなしのキーも使える
- **アプリを起動できる** — `exec`（i3 の `$mod+Return` 相当）
- **レイアウトを強制する** — 掴んで動かされても、外部から座標を書き換えられても元へ戻す
- **内蔵の見た目** — フォーカス枠線（タイル全部にも描ける）、
  ワークスペース番号（メニューバー / HUD。**中身のある番号だけを並べる**）、
  ワークスペースごとの壁紙
- **外から動かせる** — `comet --send "workspace 3"` / `comet --query workspaces`。
  i3 の `i3-msg` と同じ役目で、状態バーやシェルスクリプトから使える
- **設定は TOML 1枚** — 保存すると自動で読み直す。
  **綴り間違いは起動時に候補付きで知らせる**（黙って無視しない）
- **単一プロセス** — 常駐は comet だけ。CPU はほぼ 0%、メモリは 40MB 前後

## 動作要件

- macOS 14 以降
- Swift 6 ツールチェイン（Xcode は不要。Command Line Tools だけで組める）
- アクセシビリティ権限

## インストール

### Nix で入れる

ビルドから導入・更新までを flake で完結できます。clone は要りません。

```bash
# 1. 固定の署名 ID を作る（一度だけ）
nix run github:satomi-1224/comet#make-signing-cert

# 2. 組んで ~/Applications へ入れて起動する
nix run github:satomi-1224/comet#install
```

設定と自動起動まで宣言的に持ちたい場合は
[Nix で宣言的に持つ](#nix-で宣言的に持つ)を見てください。更新も switch で完結します。

### スクリプトで入れる

```bash
git clone https://github.com/satomi-1224/comet.git
cd comet

# 1. 署名 ID を作る（一度だけ。省略すると入れ替えのたびに権限を求められます）
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

### Nix で宣言的に持つ

本体・設定・自動起動をまとめて宣言できます。**更新も switch で完結します。**

flake を input に足して、使っている仕組みに合わせてモジュールを読み込みます。

<details open>
<summary><b>home-manager</b>（推奨）</summary>

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

</details>

<details>
<summary><b>nix-darwin</b>（home-manager を使っていない場合）</summary>

```nix
{
  inputs.comet.url = "github:satomi-1224/comet";

  # nix-darwin の設定
  imports = [ inputs.comet.darwinModules.default ];

  services.comet = {
    enable = true;
    user = "あなたのユーザ名";   # 省略時は system.primaryUser
    settings = { /* 上と同じ */ };
  };
}
```

`services.comet` の選択肢は `programs.comet` と同じです（`user` だけ増えます）。

> [!NOTE]
> nix-darwin の activation は root で走り、`sudo -u` で利用者へ降ります。
> 環境によってはキーチェーンに届かず**署名し直しに失敗**して ad-hoc のままになります。
> その場合は端末から一度だけ `nix run github:satomi-1224/comet#install` を実行してください。
> home-manager 側の activation は利用者のセッションで走るのでこの問題はありません。

</details>

| オプション | 既定 | 内容 |
|---|---|---|
| `enable` | `false` | 有効にする |
| `package` | この flake の comet | 導入する本体。`null` にすると本体を Nix の管理外にする |
| `settings` | `{}` | `config.toml` の内容（TOML へ変換して置く） |
| `settingsFile` | `null` | 書いてある `config.toml` をそのまま置く。`settings` より優先 |
| `app` | `~/Applications/comet.app` | 本体を置く場所 |
| `signingIdentity` | `"comet-dev"` | 置いたあと署名し直す ID。`null` で署名し直さない |
| `startService` | `true` | launchd agent として登録し、ログイン時に起動する |
| `logFile` | `~/Library/Logs/comet.log` | launchd から起動したときのログ |

**キーバインドは置き換えです**（既定へ追加されるのではありません）。書くなら必要なものを
全部書いてください。設定は保存を検知して自動で読み直すので、switch すればそのまま反映されます。

> [!NOTE]
> `enable = false` にすると launchd の登録と設定ファイルは消えますが、
> **`app` に置いた本体は残ります**（ストアの外なので Nix が回収しません）。
> 消すなら `rm -rf ~/Applications/comet.app` と
> `rm -rf ~/Library/Application\ Support/comet` を手で実行してください。

#### 更新する

```bash
nix flake update comet
home-manager switch          # nix-darwin なら darwin-rebuild switch
```

本体を組み直し、`app` へ入れ替え、launchd を上げ直すところまで switch がやります。
**本体が変わっていなければ何もしません**（常駐中の comet を落としません）。

#### なぜストアから直接動かさないのか

アクセシビリティ権限は**コード署名の同一性**に紐づきます。Nix ストアの中では
キーチェーンに触れないため ad-hoc 署名しかできず、内容が変わるたびに cdhash が変わって
権限が外れます。そこでモジュールは、ストアで組んだものを `app`（既定
`~/Applications/comet.app`）へ写し、**固定の署名 ID で署名し直します**。
署名の要件が更新をまたいで同じになるので、権限を付け直さずに済みます。

```
designated => identifier "local.comet" and certificate leaf = H"50e54a3c…"
                                          ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                                          パスにも内容にも依らないので更新しても外れない
```

署名 ID は `nix run github:satomi-1224/comet#make-signing-cert` で作れます。
無い場合は ad-hoc のまま進み（動作はします）、警告を出します。

#### ビルドについて

`nix build .#comet` で `comet.app` が組めます。ただし**コンパイラだけはホストの
Command Line Tools / Xcode を借ります**。comet は Swift 6 を要求しますが nixpkgs の
Swift は 5.10 のためです。そのためパッケージは `__noChroot = true` を付けており、
ビルドには次が要ります。

- Swift 6 が入った Command Line Tools か Xcode
- `nix.settings.sandbox` が `false` か `relaxed`（`relaxed` の場合は trusted-users に入っていること）

依存パッケージ（TOMLDecoder）はハッシュ固定でストアから与えるので、
ビルド中にネットワークへは出ません。

> [!TIP]
> `import Foundation` を含むコンパイルが
> `redefinition of module 'SwiftBridging'` で落ちる Mac があります。
> Xcode 15 期の `<toolchain>/usr/include/swift/module.modulemap` が残っているのが原因で、
> パッケージ側で VFS overlay を使って自動的に回避します。
> 恒久的に直すなら `sudo mv <toolchain>/usr/include/swift/module.modulemap{,.disabled}`。

#### flake の出力

| 出力 | 内容 |
|---|---|
| `packages.<system>.comet` | `comet.app`（`bin/comet` も置くので `--send` / `--query` が使える） |
| `packages.<system>.comet-debug` | debug ビルド |
| `apps.<system>.default` | ストアから前景で起動する（ログが端末に出る。常用には向かない） |
| `apps.<system>.install` | 組んで `~/Applications/comet.app` へ入れて起動する |
| `apps.<system>.make-signing-cert` | 固定の署名 ID を作る |
| `homeManagerModules.default` | home-manager モジュール（`programs.comet`） |
| `darwinModules.default` | nix-darwin モジュール（`services.comet`） |
| `overlays.default` | `pkgs.comet` を足す |

### ログイン時に起動する

Nix でモジュールを読み込んでいれば `startService = true`（既定）で launchd へ登録されます。
そうでない場合は設定に `start-at-login = true` を書きます。

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
| `--send <command>` | 常駐している comet へコマンドを送る（i3 の `i3-msg`） |
| `--query <topic>` | 状態を問い合わせる（`workspaces` / `windows` / `monitors` / `tree` / `state`） |
| `--help` | ヘルプ |

### 外から動かす（i3 の `i3-msg` 相当）

常駐している comet へ UNIX ドメインソケット経由でコマンドを送れます。
**設定に書ける綴りがそのまま使えます。**

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

## 開発

```bash
swift build                 # ビルド
./scripts/test.sh           # 単体テスト（648 件）
./scripts/verify.sh         # 実機検証（77 項目。実際にウィンドウを動かして画素と座標で判定）
./scripts/build-app.sh      # .app を組み立てる
nix build .#comet           # .app を Nix で組む（冷えた状態から組み直す）
nix develop                 # 開発用のシェル
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

## ライセンス

[MIT](LICENSE)

## 謝辞

設定とコマンドの綴りは [AeroSpace](https://github.com/nikitabobko/AeroSpace) を参考にしています。
