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

- **開いたら並ぶ** — 開くと自動でタイルされ、閉じると残りが詰まる
- **キーボードで完結** — フォーカス・移動・リサイズ・分割・フローティング、i3 の `mode`（キーの層）
- **ワークスペース 10 個** — macOS の操作スペースを使わないので**切替にアニメーションが挟まらない**
- **複数ディスプレイ** — i3 の output と同じ考え方。ウィンドウもワークスペースも出力間で動かせる
- **レイアウトを強制する** — 掴んで動かされても、外から座標を書き換えられても元へ戻す
- **外から動かせる** — `comet --send "workspace 3"` / `comet --query workspaces`（i3 の `i3-msg` 相当）
- **単一プロセス** — 常駐は comet だけ。CPU はほぼ 0%、メモリは 40MB 前後

## 動作要件

macOS 14 以降とアクセシビリティ権限。ビルドには Swift 6 のツールチェインが要ります
（Xcode は不要で Command Line Tools だけで組めます）。

## インストール

<details open>
<summary><b>Nix</b></summary>

```bash
nix run github:satomi-1224/comet#make-signing-cert   # 固定の署名 ID（一度だけ）
nix run github:satomi-1224/comet#install             # 組んで ~/Applications へ入れて起動
```

設定と自動起動まで宣言的に持つなら [docs/nix.md](docs/nix.md) を見てください。
`nix flake update comet && switch` で更新まで完結します。

</details>

<details>
<summary><b>スクリプト</b></summary>

```bash
git clone https://github.com/satomi-1224/comet.git && cd comet
./scripts/make-signing-cert.sh      # 固定の署名 ID（一度だけ）
./scripts/install-app.sh release    # 組んで ~/Applications へ入れる
```

</details>

設定の雛形を置きます（宣言的に持つなら要りません）。

```bash
mkdir -p ~/.config/comet
~/Applications/comet.app/Contents/MacOS/comet --print-default-config > ~/.config/comet/config.toml
```

初回起動時に**アクセシビリティ権限**を求められます。
「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で許可してください。

> [!IMPORTANT]
> **アクセシビリティ権限はコード署名の同一性に紐づきます。** ad-hoc 署名のままだと
> 内容が変わるたびにハッシュが変わり、入れ替えるたびに許可を求められます。
> 上の署名 ID を先に作っておくと出なくなります。

### 必要なシステム設定

| 設定 | 値 | 理由 |
|---|---|---|
| Mission Control > ディスプレイごとに個別の操作スペース | オフ | 操作スペースが分かれるとワークスペースの管理と衝突する |
| Mission Control > 最新の使用状況に基づいて操作スペースを自動的に並べ替える | オフ | 並び順が動くと切替先が定まらない |
| Stage Manager | オフ | ウィンドウの位置を横取りされる |
| アクセシビリティ > 視差効果を減らす | オン（推奨） | 切替が速く見える |

## 使い方

`alt` を修飾キーに、i3 と同じ手つきで動きます。よく使うものだけ抜き出すと:

| キー | 動作 |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` | 左・下・上・右へフォーカス |
| `alt-shift-h/j/k/l` | ウィンドウを移動 |
| `alt-ctrl-h/j/k/l` | 分割の境界を動かす（押しっぱなしで連続） |
| `alt-1` … `alt-0` | ワークスペース切替 |
| `alt-shift-1` … `alt-shift-0` | ウィンドウを別のワークスペースへ移して追従 |
| `alt-b` / `alt-v` | 次のウィンドウを左右／上下に分けて入れる（`split h` / `split v`） |
| `alt-shift-f` | フローティングとタイルを切り替える |
| `alt-r` | リサイズの層へ入る（`esc` で戻る） |
| `alt-enter` | ターミナルを開く（`exec`） |
| `alt-s` / `alt-shift-s` | 次のディスプレイへフォーカス／ウィンドウを移す |
| `ctrl-alt-shift-q` | 終了（退避中のウィンドウを戻してから終わる） |

全部の一覧・設定できる項目・コマンドの綴りは [docs/configuration.md](docs/configuration.md) にあります。

## ドキュメント

| | |
|---|---|
| [docs/configuration.md](docs/configuration.md) | 設定ファイル、既定のキーバインド、コマンド一覧、`--send` / `--query` |
| [docs/nix.md](docs/nix.md) | home-manager / nix-darwin モジュール、更新、ビルドの前提 |
| [docs/design.md](docs/design.md) | しくみ（なぜそう作ったか）、制限、i3 との対応表 |

## 開発

```bash
./scripts/test.sh      # 単体テスト（741 件）
./scripts/verify.sh    # 実機検証（27 節 103 項目。実際にウィンドウを動かして画素と座標で判定）
./scripts/build-app.sh # .app を組み立てる
nix build .#comet      # .app を Nix で組む
```

> [!NOTE]
> **`swift test` を直に叩かないでください。** Xcode を入れていない環境では
> Testing.framework の解決に失敗します。壊れた `module.modulemap` が残っている Mac では
> 冷えた状態からのビルドも通りません。`./scripts/test.sh` が両方の設定を渡します。

## 制限

- **入らないときは重なります。** macOS のアプリは指定より小さくならないので、
  最小寸法の合計が領域を超えると避けようがありません（理由と打つ手は警告に出ます）
- タブ／スタック表示（i3 の `layout tabbed` / `stacking`）はありません。
  macOS 側にタブ帯を描く手段が無いためです
- **scratchpad** と **mark** はありません
- 他のタイリングウィンドウマネージャと同時に動かすと、互いの配置を奪い合います

詳しくは [docs/design.md](docs/design.md#制限) を見てください。

## ライセンス

[MIT](LICENSE)

## 謝辞

- **[i3](https://i3wm.org/)** — 操作の語彙はここに合わせています。ワークスペース、
  output の扱い、`mode` によるキーの層、`focus` / `move` / `split` の綴り。
  「触った感じが i3 と同じ」を目標にしています
- **[AeroSpace](https://github.com/nikitabobko/AeroSpace)** — macOS で同じことをする先行例。
  設定ファイルとコマンドの綴りを参考にしています
