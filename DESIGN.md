# comet — macOS Tiling Window Manager 設計・実装仕様書

> プロジェクト名: `comet`（バイナリ名 / バンドル ID `local.comet` / 設定ディレクトリ `~/.config/comet/`）
> 対象読者: 本プロジェクトを実装するAIエージェントおよび開発者
> 目的: **このドキュメント単体で実装に着手できる**粒度の仕様を提供する
> 進捗の現在地は [PROGRESS.md](PROGRESS.md) を参照

---

## 0. 前提と読み方

### 0.1 実行環境（実測値）

| 項目 | 値 |
|---|---|
| OS | macOS 26.5.2 (Tahoe) / Build 25F84 |
| CPU | Apple M4 |
| SIP | **有効**（無効化しない方針） |
| ディスプレイ | 内蔵 2560×1664 Retina（外部モニタは接続するが**同時1画面運用**） |
| dotfiles管理 | nix + home-manager（設定ファイルはNixストアからのシンボリックリンク） |

### 0.2 このドキュメントの原則

- **決定事項には理由を併記する。** 実装時に「なぜそうなっているか」を再導出しなくて済むようにする。
- **性能に関わる決定は最優先で守る。** 本プロジェクトの存在理由は性能であり、機能ではない。
- **「後で最適化する」が通用しない箇所を §3 で明示する。** 非同期AXアクセスは後付けできない。

---

## 1. プロジェクト概要

### 1.1 背景

現在、以下の2プロセス構成で運用している。

| レイヤ | ツール | 担当 |
|---|---|---|
| タイリングWM | AeroSpace | ワークスペース、BSPレイアウト、ウィンドウ操作 |
| ユーティリティ | Hammerspoon | アプリランチャー、クリップボード履歴、スニペット、アプリ切替 |

AeroSpace自体の機能には概ね満足しているが、**速度・体感の質**に不満がある。本プロジェクトはAeroSpaceを置き換えるWMコアを、性能を第一目標としてSwiftで実装する。

### 1.2 ゴール

1. AeroSpaceの操作モデル（i3ライクなBSPツリー + 10ワークスペース）を維持したまま置き換える
2. 以下の4症状を解消する（**これが本プロジェクトの成否を決める**）
   - **症状A**: 新規ウィンドウを開いた瞬間、デフォルト位置に一瞬出てからタイル位置へ飛ぶ
   - **症状B**: リサイズキーを連打すると追従しない・飛ぶ・戻る
   - **症状C**: ワークスペース切替が遅い・ちらつく
   - **症状D**: 壁紙変更がワンテンポ遅れる
3. 壁紙切替 / フォーカス枠線 / ワークスペースインジケータをWM本体に内蔵する
4. 設定をTOMLで記述し、nix + home-managerから生成できる形にする

### 1.3 非ゴール（明示的にスコープ外）

| 項目 | 理由 |
|---|---|
| アプリランチャー | 別プロジェクトとして分離。当面Hammerspoon継続 |
| クリップボード履歴 | 同上 |
| スニペット | 同上 |
| アプリ/ウィンドウ巡回（Alt+F, Alt+D） | 同上。ただしWM側のfocusコマンドと機能重複するため §12.3 で整理 |
| 外部連携CLI / IPC | 不要と判断。全操作をホットキーで完結させる |
| 同時マルチモニタレイアウト | 1画面運用。ただし**付け替えの検知と復元は必要**（§7.6） |
| macOSネイティブSpacesとの統合 | 画面外退避方式を採用するため不要（§4.3） |
| App Store配布 / 一般公開 | 個人利用前提。private API使用の制約を受けない |

### 1.4 設計方針（サマリ）

| 論点 | 決定 | 理由 |
|---|---|---|
| 言語 | Swift | AppKit / Accessibility API に最短距離。型定義が公式に揃う |
| レイアウトモデル | BSPツリー（i3/AeroSpace式） | 現行の操作感を維持する |
| ワークスペース実装 | 画面外退避方式 | SIP有効のまま動作。切替にOSアニメーションが挟まらない |
| private API | **SIP有効のまま使える範囲で使う** | `_AXUIElementGetWindow` / `AXEnhancedUserInterface` 等。SIP無効化は行わない |
| 設定形式 | TOML | 現行AeroSpace設定からの移行コスト最小。nixから生成しやすい |
| 性能目標 | 数値目標は置かず、症状A〜Dの解消で判定 | ただし計測機構は debug ビルドに常設する（§11） |

---

## 2. 現状の資産と移行対象

### 2.1 移行対象（AeroSpace設定 → 本プロジェクト）

現行 `~/.aerospace.toml` の全設定を移植する。

**一般設定**
```
start-at-login = true
enable-normalization-flatten-containers = true
enable-normalization-opposite-orientation-for-nested-containers = true
default-root-container-layout = 'tiles'
default-root-container-orientation = 'auto'
on-focused-monitor-changed = ['move-mouse monitor-lazy-center']
exec-on-workspace-change = [wallpaper.sh]   # → 内蔵化（§8.3）
gaps: inner 5 / outer 5（全方向）
```

**キーバインド（全26個）** → §9 に完全な移植表を記載

**ウィンドウルール**
```
com.apple.systempreferences → floating
com.apple.finder            → floating
```

### 2.2 内蔵化する外部スクリプト

現行の壁紙切替 `~/.config/aerospace/wallpaper.sh`:

```bash
WORKSPACE="$AEROSPACE_FOCUSED_WORKSPACE"
WALLPAPER="$(get_wallpaper "$WORKSPACE")"
osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"$WALLPAPER\""
```

**これが症状Dの原因である。** 内訳:

| 工程 | 概算コスト |
|---|---|
| `/bin/bash` プロセス起動 | 5〜15ms |
| `osascript` プロセス起動（AppleScript処理系の初期化を含む） | 100〜300ms |
| System Events へのAppleEvent送信（System Events自体が未起動なら起動も） | 100ms〜1s |
| 合計 | **概ね 0.2〜1.5秒** |

`NSWorkspace.setDesktopImageURL(_:for:options:)` をプロセス内で直接呼べば**数ms**で済む。§8.3 参照。

なお現行 `wallpaper_config.sh` は `~/Pictures/wallpapers/wallpaper{1..5}.jpg` を参照するが、**このディレクトリの実在は未確認**。実装時に確認し、無ければ設定側で「未設定のワークスペースは壁紙を変更しない」挙動にする。

### 2.3 移行しないもの

Hammerspoon側の `app_switcher.lua` / `clipboard.lua` / `search.lua` / `command_launcher*.lua` / `snippets*.lua` はそのまま残す。ただし `command_launcher.lua` 内の以下はWM機能と重複する:

```lua
-- 修飾キー+BS: フォーカス中のウィンドウを閉じる
hs.hotkey.bind(M.mods, "delete", function() ... win:close() ... end)
```

→ WM側に `close-window` コマンドを実装し、Hammerspoon側からは削除するのが望ましい（§9.3）。

---

## 3. 性能問題の根本原因分析

**本章が本プロジェクトの中核である。** アーキテクチャはすべてここから導出される。

### 3.1 Accessibility API の構造的制約

macOSで他プロセスのウィンドウを操作する唯一のSIP互換手段は Accessibility API (AX API) である。その性質:

#### (a) すべての呼び出しが同期プロセス間通信である

`AXUIElementSetAttributeValue` / `AXUIElementCopyAttributeValue` は、**対象アプリのメインスレッドにメッセージを送り、処理されるまで呼び出し側スレッドをブロックする**。

- 対象アプリがビジー（重いレンダリング、同期I/O、ビーチボール）なら、その間ずっとブロックする
- デフォルトのメッセージングタイムアウトは**6秒**
- → **メインスレッドでAX呼び出しを行うと、他人のアプリの都合でWM全体が固まる**

これが「カクつく」の最大の構造要因である。

#### (b) 位置とサイズが別属性である

ウィンドウの矩形を変えるには2回の呼び出しが必要:

```swift
AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
AXUIElementSetAttributeValue(window, kAXSizeAttribute   as CFString, sizeValue)
```

`kAXFrameAttribute` は**読み取り専用**であり、書き込みには使えない。したがって:

- 最低2回のIPCが必要
- 2回の間に中間状態（新しい位置・古いサイズ）が画面に描画されうる → **これが「パラつき」の正体**
- 一括設定するpublic APIは存在しない

> **補足**: SkyLight (`SLSMoveWindowWithGroup` 等) なら1回で済むが、**他プロセスのウィンドウに対してはSIP無効化（yabaiのscripting addition相当）が必須**であり、本プロジェクトの方針外。したがって「2回のIPC」は受け入れた上で、**中間状態が見えないよう順序と非同期性で対処する**。

#### (c) 読み取りも同じコストである

役割・サブロール・タイトル・最小化状態などの属性読み取りも1つずつIPCが発生する。属性5個を個別に読むと5往復。

**対策**: `AXUIElementCopyMultipleAttributeValues` は**public APIでありながら複数属性を1往復で取得できる**。すべての読み取りをこれに寄せる。

```swift
public func AXUIElementCopyMultipleAttributeValues(
    _ element: AXUIElement,
    _ attributes: CFArray,
    _ options: AXCopyMultipleAttributeOptions,
    _ values: UnsafeMutablePointer<CFArray?>
) -> AXError
```

#### (d) 並列性はプロセス単位で存在する

AXメッセージは**対象アプリごとにシリアライズされる**が、**異なるアプリへの呼び出しは真に並列実行できる**。

→ **アプリ（PID）ごとに専用のDispatchQueueを持てば、N個のアプリに対してN並列で操作を発行できる。** これがワークスペース切替高速化の主武器である。

#### (e) `AXEnhancedUserInterface`

VoiceOver等の支援技術向けの非公開属性。これが `true` のアプリでは、ウィンドウのリサイズ時に追加処理やアニメーションが挟まり、`SetAttributeValue` が顕著に遅くなる。Electron系や一部AppKitアプリで、支援技術（=WM自身）がAX接続した時点で自動的に `true` になることがある。

**対策**: ウィンドウ操作の直前に `false` にし、直後に元の値へ戻す。yabai / Rectangle が採用している既知のワークアラウンド。

### 3.2 症状A: 新規ウィンドウを開いた瞬間のちらつき

**発生機序**

```
[アプリ] ウィンドウ生成 → アプリ自身が決めた位置で表示（この時点で画面に出る）
                              ↓ AXWindowCreated 通知
[WM]                         通知受信 → 属性読み取り → レイアウト計算 → 位置/サイズ設定
                                                                        ↓
                                                              タイル位置へ移動（見える）
```

「アプリが表示してからWMが動かすまで」の時間がそのままちらつきとして見える。

**SIP有効下では、他プロセスのウィンドウの初回描画を止める手段は存在しない。** したがって**通知受信から適用完了までの時間を最小化する**ことが唯一の対策となる。現行AeroSpaceでの遅延要因と対策:

| 遅延要因 | 対策 |
|---|---|
| AXObserverの登録がウィンドウ生成後になる | アプリ起動時（`NSWorkspace.didLaunchApplicationNotification`）に**事前登録**する（§6.4） |
| 属性を1つずつ読む（role, subrole, position, size…で5往復） | `AXUIElementCopyMultipleAttributeValues` で**1往復**にする |
| 通知処理・レイアウト計算・適用の間でスレッドを往復する | 通知受信 → 状態更新 → 適用の経路からスレッドホップを削る（§4.2） |
| 適用がキューで他の処理待ちになる | 新規ウィンドウ適用を**最優先**でPIDキューに投入する |

**追加対策（体感面）**: 新規ウィンドウ適用の**直前ではなく直後**にフォーカス枠線を目標位置へ移動させると、ちらつきが視覚的に補正されて感じられる。枠線は自プロセスのNSWindowなので即座に動かせる（§8.2）。

### 3.3 症状B: リサイズ連打時の追従不良

**発生機序**

macOSのキーリピートは概ね 25〜30回/秒。1回のリサイズにつきAX呼び出しが（対象ウィンドウ数 × 2）回発生する。BSPツリーでリサイズすると**隣接ウィンドウも同時に変わる**ため、1打鍵で最低4回のIPCになる。

```
打鍵1 → [IPC ×4] ────────────→ 完了
打鍵2 →         [IPC ×4] ────────────→ 完了     ← 打鍵から適用まで遅延が累積
打鍵3 →                 [IPC ×4] ────────────→
...
キーを離した後もキューに溜まった分が処理され続ける → 「飛ぶ」「戻る」
```

**対策: 状態更新と適用の分離 + コアレス（合成）**

```
打鍵1 → ツリーの比率を更新（メモリ操作、マイクロ秒） → 目標フレームを pending に記録
打鍵2 → ツリーの比率を更新                          → pending を上書き
打鍵3 → ツリーの比率を更新                          → pending を上書き
                                    ↓ 8ms ごとのティック
                              pending の最新値だけを1回適用
```

- **中間状態は捨てる。** 30回打鍵しても適用は最大でティック回数分（120回/秒 → 実質数回）
- 適用中（in-flight）のウィンドウには次を投げず、完了後に最新の pending を投げる
- これにより「キューに詰まって遅れて届く」現象が原理的に起こらなくなる

**さらに**: リサイズ専用モード（i3の `mode`）を用意すれば、修飾キーなしの `h/j/k/l` 連打が可能になり、修飾キー押下の負荷も消える。§9.4 で扱う。

### 3.4 症状C: ワークスペース切替の遅さ・ちらつき

**発生機序**

画面外退避方式では、切替のたびに以下が発生する:

```
旧ワークスペースの全ウィンドウ  → 画面外座標へ移動   (N₁ × IPC)
新ワークスペースの全ウィンドウ  → タイル位置へ復帰   (N₂ × IPC × 2)
```

これを逐次実行すると、**ウィンドウが1枚ずつ順番に現れる**のが見えてしまう。これが「ちらつき」の正体。

**対策1: PIDごとの並列適用（最大の効果）**

ウィンドウがM個のアプリに分散していれば、M並列で処理できる。5アプリに分散していれば所要時間は約1/5。

**対策2: 復帰時の呼び出しを半減する**

退避時に**サイズを変えず位置だけ動かす**。復帰時もサイズが変わっていなければ**位置だけ戻す**。

```
退避: setPosition(offscreen)           ← IPC 1回（sizeは触らない）
復帰: setPosition(target)              ← IPC 1回（sizeは既に正しい）
```

レイアウトが変化していない限り、切替コストは **1ウィンドウあたりIPC 1回**になる。変化した場合のみサイズも設定する（dirtyフラグで管理、§7.4）。

**対策3: 表示を先に、退避を後に**

同一バッチで発行しつつ、各PIDキューにおいて**表示側の操作を先頭に置く**。ユーザーの目には新ワークスペースが先に完成して見える。

**対策4: 壁紙を同一フレームで切り替える**

外部プロセス起動を廃し、ウィンドウ配置の発行と同時に `NSWorkspace.setDesktopImageURL` を呼ぶ（§8.3）。

**対策5: フォーカス復元の確定的な処理**

ワークスペースごとに「最後にフォーカスしていたウィンドウ」を保持し、切替時に確実に復元する（§7.5）。現行で「戻ったらフォーカスがどこにもない」状態が起きるのはこの保持が無いか失われるため。

### 3.5 症状D: 壁紙変更の遅延

§2.2 で分析済み。`osascript` + System Events → `NSWorkspace.setDesktopImageURL` に置換。

**注意**: macOS 14 (Sonoma) 以降、壁紙システムが刷新され `setDesktopImageURL` の挙動に差異が報告されている（設定アプリ上の表示と実態がずれる、複数ディスプレイでの扱いなど）。**macOS 26 での動作は実装初期に必ず検証すること。** 動作しない場合のフォールバックは §12.5。

---

## 4. アーキテクチャ

### 4.1 全体構成

```
┌──────────────────────────────────────────────────────────────┐
│                      Main Thread (@MainActor)                 │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                        Engine                           │  │
│  │  状態機械の中核。すべての状態変更はここを通る。         │  │
│  │  ★ 絶対にブロックしない（同期AX呼び出しを行わない）     │  │
│  └───┬──────────────┬──────────────┬─────────────────┬────┘  │
│      │              │              │                 │       │
│  ┌───▼────┐  ┌──────▼──────┐  ┌───▼─────┐  ┌────────▼─────┐ │
│  │ Layout │  │  Workspace  │  │ Window  │  │   Monitor    │ │
│  │ Engine │  │   Manager   │  │Registry │  │   Manager    │ │
│  │(純粋関数)│  │             │  │         │  │              │ │
│  └────────┘  └─────────────┘  └─────────┘  └──────────────┘ │
│                                                               │
│  ┌────────────┐  ┌──────────────┐  ┌─────────────────────┐  │
│  │  Hotkey    │  │  Decoration  │  │  AXObserverHub      │  │
│  │  Manager   │  │ (枠線/HUD/   │  │  (通知の受信のみ)   │  │
│  │  (Carbon)  │  │  壁紙)       │  │                     │  │
│  └────────────┘  └──────────────┘  └─────────────────────┘  │
└───────────────────────────┬───────────────────────────────────┘
                            │ 目標フレームの集合を渡す（非同期・ノンブロッキング）
                ┌───────────▼────────────┐
                │    FrameScheduler       │  8ms ティックでコアレス
                │  pending / applied /    │
                │  in-flight を管理        │
                └───────────┬─────────────┘
                            │ PIDごとに振り分け
        ┌───────────────────┼───────────────────┐
        │                   │                   │
┌───────▼───────┐   ┌───────▼───────┐   ┌───────▼───────┐
│ Queue(pid: A) │   │ Queue(pid: B) │   │ Queue(pid: C) │  ← 真の並列
│  AX write ×N  │   │  AX write ×N  │   │  AX write ×N  │
└───────────────┘   └───────────────┘   └───────────────┘
        │                   │                   │
   [Chrome.app]        [WezTerm.app]        [Slack.app]
```

### 4.2 スレッドモデル（**最重要の設計制約**）

| スレッド | 担当 | 禁止事項 |
|---|---|---|
| **Main** | 状態機械、レイアウト計算、通知受信、ホットキー処理、UI描画 | **同期AX呼び出しを一切行わない** |
| **PIDキュー**（PIDごとに1本、`.userInteractive`） | 対象アプリへのAX読み書き | 状態を直接変更しない（結果はMainへ返す） |
| **FrameSchedulerキュー**（1本） | ティック駆動とディスパッチ | 重い処理を行わない |

**この分離は後付けできない。** 最初のコミットから守ること。「まず動くものを作って後で非同期化する」を選ぶと、状態管理の前提が全面的に変わり、事実上の作り直しになる。

**根拠**: AX呼び出しは相手アプリの都合で最大6秒（タイムアウト設定後でも数十〜数百ms）ブロックしうる。Mainがブロックすればホットキーも通知処理も描画も止まる。これが「WMが固まる」の全原因である。

**メッセージングタイムアウトの設定**

```swift
// アプリ要素ごとに設定する。0.1秒 = 100ms。
// この値を超えたら AXError.cannotComplete が返る（=そのアプリだけ諦める）
AXUIElementSetMessagingTimeout(appElement, 0.1)
```

これにより、ハングしたアプリが1つあっても他のアプリの操作は影響を受けない。

### 4.3 ワークスペースの実現方式

**採用: 画面外退避方式**

- 非表示ワークスペースに属するウィンドウを、全モニタの矩形の外側に移動する
- macOSネイティブのSpacesは**常に1つだけ**使う

| 項目 | 内容 |
|---|---|
| 退避先座標 | 全モニタのunion矩形の下方。例: `y = unionRect.maxY + 100000` |
| 利点 | SIP有効のまま動作 / 切替にOSアニメーションが挟まらない / 状態を完全に自前管理できる |
| 欠点 | Mission Control・Cmd+Tab・Dockから見ると全ウィンドウが同一Space上に見える |
| 欠点 | 画面録画・スクリーンショット（全画面キャプチャ）に退避中ウィンドウが写る可能性 |

**必須のシステム設定（ユーザー側で設定すること）**

| 設定 | 値 | 理由 |
|---|---|---|
| Mission Control > ディスプレイごとに個別の操作スペース | **オフ** | ネイティブSpaceを1つに保つ |
| Mission Control > 最新の使用状況に基づいて操作スペースを自動的に並べ替える | **オフ** | 順序が動くと座標系の前提が崩れる |
| Stage Manager | **オフ** | ウィンドウ配置を横取りする |
| デスクトップとDock > ウインドウをアプリケーションごとにグループ化 | 任意 | |
| アクセシビリティ > 視差効果を減らす | **オン推奨** | ウィンドウ移動時のOSアニメーションを抑制 |

**ネイティブフルスクリーン（緑ボタン）は独自Spaceを作るため、本方式と根本的に衝突する。** フルスクリーン化されたウィンドウは "unmanaged" として扱い、レイアウトから除外する（§5.2）。WM側の `fullscreen` コマンドは、ネイティブフルスクリーンではなく**モニタ矩形いっぱいへのタイル配置**として実装する。

---

## 5. データモデル

### 5.1 BSPツリー

i3 / AeroSpace と同じモデル。**葉がウィンドウ、内部ノードがコンテナ**。

```swift
enum Orientation {
    case horizontal   // 子を左右に並べる
    case vertical     // 子を上下に並べる
}

/// ツリーのノード。参照型（親への弱参照を持つため）
class Node {
    weak var parent: ContainerNode?
}

final class WindowNode: Node {
    let windowID: CGWindowID
    /// 最後にフォーカスされた時刻（focus-direction時の降下先決定に使う）
    var lastFocusedAt: UInt64 = 0
}

final class ContainerNode: Node {
    var orientation: Orientation
    var children: [Node]
    /// 各子の占有比率。合計 1.0。children と同じ長さを常に保つ
    var weights: [Double]
}
```

**不変条件（すべての木操作の後で保証すること）**

1. `container.children.count == container.weights.count`
2. `container.weights.reduce(0, +) ≈ 1.0`（誤差 1e-9 以内。ずれたら再正規化）
3. すべての子の `parent` が自分を指している
4. 空のコンテナは存在しない（子が0になったら親から除去）
5. **正規化ルール1（flatten-containers）**: 子が1つだけのコンテナは、その子を親に昇格させて自身を消す
6. **正規化ルール2（opposite-orientation-for-nested）**: コンテナの子コンテナは、親と逆のorientationを持つ

ルール5・6は現行AeroSpace設定で有効なので、既定で有効にする。設定で切替可能にする。

**正規化の実行タイミング**: 木を変更するすべてのコマンドの**直後、レイアウト計算の直前**。

```swift
func normalize(_ root: ContainerNode, config: NormalizationConfig) {
    // 深さ優先で葉から処理する（子から先に潰さないと親の判定が狂う）
}
```

### 5.2 ウィンドウ

```swift
struct ManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    let axElement: AXUIElement
    let bundleID: String?

    /// レイアウト管理下にあるか
    var state: WindowState

    /// 最後にWMが適用した矩形（AX座標系 = top-left origin）
    var appliedFrame: CGRect?
    /// AX通知で観測した実際の矩形
    var observedFrame: CGRect?

    /// 所属ワークスペース
    var workspace: WorkspaceID
}

enum WindowState {
    case tiled          // BSPツリーに参加
    case floating       // ツリー外。位置は自由
    case unmanaged      // 完全に無視（ネイティブフルスクリーン、対象外subrole など）
    case hidden         // 非表示ワークスペースに属し、画面外に退避中
}
```

**管理対象の判定**（ウィンドウ検出時に1回だけ判定し、結果をキャッシュする）

| 条件 | 判定 |
|---|---|
| `kAXRoleAttribute != "AXWindow"` | unmanaged |
| `kAXSubroleAttribute != "AXStandardWindow"` | unmanaged（ダイアログ・シート・ポップオーバー・フローティングパネルを除外） |
| `kAXFullScreenAttribute == true` | unmanaged（§4.3） |
| `kAXMinimizedAttribute == true` | 一時的に除外（復帰時に再参加） |
| サイズが極端に小さい（例: 幅または高さ < 40pt） | unmanaged |
| ウィンドウルールで `floating` 指定 | floating |
| 上記以外 | tiled |

**CGWindowID の取得**（private API、SIP不要）

```swift
// ApplicationServices の非公開シンボル。dlsym でのフォールバックを用意すること（§12.2）
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ outID: UnsafeMutablePointer<CGWindowID>) -> AXError
```

CGWindowIDを主キーにする理由: AXUIElementは同一ウィンドウに対して複数のインスタンスが生成されうる（`CFEqual` は一致するが、辞書キーとして扱いにくい）。CGWindowIDは安定した一意識別子である。

### 5.3 ワークスペース

```swift
typealias WorkspaceID = Int   // 1...10

final class Workspace {
    let id: WorkspaceID
    /// タイル配置のルート。空でもコンテナは常に存在する
    let root: ContainerNode
    /// フローティングウィンドウ（ツリー外、順序はz-order相当）
    var floating: [CGWindowID]
    /// このワークスペースを離れる直前にフォーカスしていたウィンドウ
    var lastFocused: CGWindowID?
    /// 割り当てられているモニタ
    var monitor: MonitorID
    /// レイアウトが変化しており、復帰時にサイズ再適用が必要か（§3.4 対策2）
    var layoutDirty: Bool
}
```

### 5.4 モニタ

```swift
struct Monitor {
    let id: MonitorID          // CGDirectDisplayID
    /// AX座標系（top-left origin）でのモニタ全体の矩形
    let frame: CGRect
    /// メニューバー・Dockを除いた作業領域（AX座標系）
    let visibleFrame: CGRect
    let isMain: Bool
}
```

### 5.5 座標系（**頻出のバグ源。必ず読むこと**）

macOSには**原点が異なる2つの座標系**が併存する。

| 座標系 | 原点 | Y軸 | 使うAPI |
|---|---|---|---|
| **AppKit座標系** | プライマリディスプレイの**左下** | 上向き | `NSScreen.frame`, `NSWindow.frame` |
| **CG / AX座標系** | プライマリディスプレイの**左上** | 下向き | `CGDisplayBounds`, `kAXPositionAttribute`, `CGWindowListCopyWindowInfo` |

**方針: 内部状態はすべて CG/AX座標系（top-left origin）で保持する。** AppKitに渡す直前だけ変換する。

```swift
enum Coord {
    /// プライマリディスプレイの高さ（AppKit座標系での全画面union矩形の maxY）
    static var primaryMaxY: CGFloat {
        // NSScreen.screens[0] が常にプライマリ（原点を含む画面）
        NSScreen.screens[0].frame.maxY
    }

    /// AppKit (bottom-left) → AX/CG (top-left)
    static func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    /// AX/CG (top-left) → AppKit (bottom-left)
    static func toAppKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }
}
```

変換式が同一なのは対合（involution）だからで、誤りではない。ただし**プライマリの高さが変わる（モニタ付け替え）と変換結果が変わる**ため、`primaryMaxY` はキャッシュせず都度取得するか、ディスプレイ再構成時に必ず更新すること。

**モニタ矩形の取得は `CGDisplayBounds` を推奨**（最初からAX座標系で得られるため変換不要）。ただし `visibleFrame`（Dock/メニューバー除外）はAppKit側にしか無いので、`NSScreen.visibleFrame` を変換して使う。

---

## 6. コンポーネント仕様

### 6.1 Engine（状態機械の中核）

**責務**: すべての状態変更の唯一の入口。コマンドを受け取り、状態を更新し、目標フレームを算出して FrameScheduler に渡す。

```swift
@MainActor
final class Engine {
    private var workspaces: [WorkspaceID: Workspace]
    private var registry: WindowRegistry
    private var monitors: MonitorManager
    private var activeWorkspace: WorkspaceID
    private var previousWorkspace: WorkspaceID?     // back-and-forth 用
    private let scheduler: FrameScheduler
    private let decoration: DecorationController

    /// すべてのコマンドはここを通る
    func execute(_ command: Command)

    /// AX通知の受け口（AXObserverHub から呼ばれる）
    func handle(_ event: AXEvent)

    /// 状態から目標フレームを計算し、schedulerへ渡す
    private func reconcile()
}
```

**`reconcile()` の処理**（すべての状態変更の後に必ず呼ぶ）

```
1. 木を正規化する（normalize）
2. アクティブワークスペースの全tiledウィンドウについて、LayoutEngine で目標矩形を計算
3. 非アクティブワークスペースの全ウィンドウについて、退避座標を目標矩形とする
4. floating ウィンドウは目標矩形なし（現状維持）
5. 上記を [CGWindowID: TargetFrame] にまとめ、scheduler.submit(_:) に渡す
6. フォーカス枠線・ワークスペースインジケータを更新（即座、AXを待たない）
```

`reconcile()` 自体は純粋なメモリ操作であり、**マイクロ秒オーダーで完了する。** 何度呼んでも安い。

### 6.2 LayoutEngine（純粋関数）

**責務**: BSPツリーとモニタ矩形から、各ウィンドウの目標矩形を計算する。**副作用を持たない。単体テストの主対象。**

```swift
struct Gaps {
    var innerHorizontal: CGFloat
    var innerVertical: CGFloat
    var outerTop, outerBottom, outerLeft, outerRight: CGFloat
}

enum LayoutEngine {
    /// ルートコンテナと利用可能矩形から、全ウィンドウの矩形を算出する
    static func compute(
        root: ContainerNode,
        area: CGRect,          // モニタの visibleFrame（AX座標系）
        gaps: Gaps
    ) -> [CGWindowID: CGRect]
}
```

**アルゴリズム**

```
compute(node, rect):
  if node is WindowNode:
      result[node.windowID] = rect
      return

  container = node as ContainerNode
  n = container.children.count
  if n == 0: return

  gap = (container.orientation == .horizontal) ? gaps.innerHorizontal : gaps.innerVertical
  totalGap = gap * (n - 1)
  available = (orientation == .horizontal ? rect.width : rect.height) - totalGap

  offset = (orientation == .horizontal ? rect.minX : rect.minY)
  for (i, child) in container.children.enumerated():
      length = available * container.weights[i]
      childRect = orientation == .horizontal
          ? CGRect(x: offset, y: rect.minY, width: length, height: rect.height)
          : CGRect(x: rect.minX, y: offset, width: rect.width, height: length)
      compute(child, childRect)
      offset += length + gap
```

**丸め処理**: Retinaでは0.5pt単位まで意味がある。`round(x * scale) / scale`（scale = backingScaleFactor）で丸め、**累積誤差で隙間や重なりが出ないよう、最後の子は残り全部を割り当てる**。

```swift
// 最後の子だけは計算値でなく「rect の残り」を使う
if i == n - 1 { length = (rect.maxX - offset) }
```

**最小サイズの考慮**: AXでサイズを設定してもアプリが拒否する（最小サイズ制約）ことがある。計算上は無視し、実際の結果はAX通知で観測して `observedFrame` に反映する。ずれが大きい場合のみログに残す（デバッグ用）。

### 6.3 FrameScheduler（コアレスと適用）

**責務**: 目標フレームを受け取り、ティック単位でコアレスし、PIDごとの並列適用を行う。**症状B・Cの対策の実装体。**

```swift
final class FrameScheduler {
    private let queue = DispatchQueue(label: "wm.scheduler", qos: .userInteractive)

    /// ウィンドウID → 目標矩形。上書き方式
    private var pending: [CGWindowID: CGRect] = [:]
    /// 最後に「適用を発行した」矩形
    private var applied: [CGWindowID: CGRect] = [:]
    /// 適用中のウィンドウ
    private var inFlight: Set<CGWindowID> = []
    /// サイズも設定する必要があるウィンドウ（§3.4 対策2）
    private var needsSize: Set<CGWindowID> = []

    private var timer: DispatchSourceTimer?

    /// Engine から呼ばれる。ノンブロッキング
    func submit(_ frames: [CGWindowID: CGRect], sizeDirty: Set<CGWindowID>)

    /// 8ms ごとのティック
    private func tick()
}
```

**`tick()` のロジック**

```
for (windowID, target) in pending:
    if inFlight.contains(windowID): continue          // 完了を待つ
    if applied[windowID] == target:                   // 変化なし
        pending.removeValue(forKey: windowID); continue

    inFlight.insert(windowID)
    applied[windowID] = target
    let setSize = needsSize.contains(windowID)

    applierPool.queue(for: window.pid).async {
        apply(window, target, setSize: setSize)
        // 完了通知
        scheduler.queue.async { inFlight.remove(windowID) }
    }
    pending.removeValue(forKey: windowID)

if pending.isEmpty && inFlight.isEmpty:
    timer.suspend()    // アイドル時はティックを止める（常駐コスト削減）
```

**ティック間隔**: 8ms（≒120Hz、ProMotionのフレーム間隔）。`DispatchSourceTimer` に `leeway` を 1ms 程度与えて省電力性を確保する。

> **代替案**: `CADisplayLink`（macOS 14+、`NSView.displayLink(target:selector:)` 経由）を使えばディスプレイのリフレッシュに正確に同期できる。ただし常時ビューが必要で、外部モニタ切替時の扱いが増える。**まずは `DispatchSourceTimer` で実装し、必要なら後で差し替える。** ここは後付け可能な数少ない箇所。

**優先度制御**: 新規ウィンドウの初回配置（症状A）は待たせず、`submit` 時に即座に `tick()` を1回走らせる（`queue.async { tick() }`）。

### 6.4 AXBridge / ApplierPool（AXアクセス層）

**責務**: すべてのAX呼び出しをここに集約する。**Engine から直接AX APIを呼んではならない。**

```swift
final class ApplierPool {
    private var queues: [pid_t: DispatchQueue] = [:]
    private let lock = NSLock()

    func queue(for pid: pid_t) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "comet.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }

    func removeQueue(for pid: pid_t)   // アプリ終了時
}
```

**ウィンドウ矩形の適用**

```swift
/// PIDキュー上で実行されること。Mainから呼んではならない。
func applyFrame(_ element: AXUIElement, _ target: CGRect, setSize: Bool, appElement: AXUIElement) {
    // 1) AXEnhancedUserInterface を一時的に無効化（§3.1 e）
    let hadEnhanced = readBool(appElement, "AXEnhancedUserInterface")
    if hadEnhanced { setBool(appElement, "AXEnhancedUserInterface", false) }
    defer { if hadEnhanced { setBool(appElement, "AXEnhancedUserInterface", true) } }

    // 2) 順序: 拡大時は size → position、縮小時は position → size
    //    中間状態で画面外へはみ出すのを避ける（§3.1 b）
    if setSize {
        if isGrowing {
            setSize(element, target.size)
            setPosition(element, target.origin)
        } else {
            setPosition(element, target.origin)
            setSize(element, target.size)
        }
    } else {
        setPosition(element, target.origin)   // ワークスペース切替はこちら（IPC 1回）
    }
}
```

**「2回設定」問題について**: 一部のアプリは position 設定後の size 設定で位置を勝手に補正する。従来のWMは `position → size → position` と3回設定して対処するが、IPCが1.5倍になる。

**本プロジェクトの方針**: 3回設定はしない。代わりに、適用後に位置とサイズを**1往復のバッチ読み**で確認し、目標とずれていた場合のみ補正を1回発行する。

> **訂正（Phase 1 で判明）**: 当初「AX 通知で追加の IPC なしに結果を観測できる」と書いていたが誤り。
> `AXWindowMoved` / `AXWindowResized` は「動いた」ことしか伝えず、位置を知るには読み取りが要る。
> さらに自前の適用でも通知が飛ぶため、無条件に読み戻すと往復が 1.5 倍になる。
> 読み戻しは「適用完了時に1回だけ」または「過去に暴れたアプリのみ」に限定すること。

```swift
// AX通知受信時（Main）
func onWindowMovedOrResized(_ id: CGWindowID, observed: CGRect) {
    registry[id]?.observedFrame = observed
    guard let target = scheduler.appliedFrame(id) else { return }
    if !observed.isApproximatelyEqual(to: target, tolerance: 1.0) {
        // WMの意図と違う → 補正を1回だけ発行（無限ループ防止のためリトライ回数を制限）
        scheduler.requestCorrection(id, target)
    }
}
```

**無限ループ防止**: 同一ウィンドウへの補正は連続3回までとし、それでも一致しなければ `floating` に降格してログに記録する。「サイズ変更を拒否するアプリ」を自動検出できる。

**読み取りのバッチ化**

```swift
let attrs = [
    kAXRoleAttribute, kAXSubroleAttribute,
    kAXPositionAttribute, kAXSizeAttribute,
    kAXTitleAttribute, kAXMinimizedAttribute,
    "AXFullScreen"
] as CFArray

var values: CFArray?
let err = AXUIElementCopyMultipleAttributeValues(
    element, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values
)
// → IPC 1往復で7属性
```

### 6.5 AXObserverHub（イベント受信）

**責務**: アプリごとに `AXObserver` を作り、通知をEngineへ中継する。

**購読する通知**

| 通知 | 用途 |
|---|---|
| `kAXWindowCreatedNotification` | 新規ウィンドウ検出（症状A） |
| `kAXUIElementDestroyedNotification` | ウィンドウ破棄 |
| `kAXFocusedWindowChangedNotification` | フォーカス追従 |
| `kAXWindowMovedNotification` | 実結果の観測・ユーザーによる手動移動の検出 |
| `kAXWindowResizedNotification` | 同上 |
| `kAXWindowMiniaturizedNotification` | 最小化 → レイアウトから外す |
| `kAXWindowDeminiaturizedNotification` | 復帰 → レイアウトに戻す |
| `kAXApplicationActivatedNotification` | アプリ切替時のフォーカス同期 |
| `kAXMainWindowChangedNotification` | 同上 |

**事前登録（症状Aの対策）**

```swift
// アプリ起動を検知した瞬間に AXObserver を登録する
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didLaunchApplicationNotification, ...
) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    self.attachObserver(pid: app.processIdentifier)
}
```

**注意**: アプリ起動直後はAXがまだ応答しない（`AXError.cannotComplete` / `.apiDisabled` が返る）ことがある。**指数バックオフでリトライする**（50ms → 100ms → 200ms → 400ms、最大5回）。リトライは当然PIDキュー上で行う。

**RunLoopSource の登録**

```swift
CFRunLoopAddSource(
    CFRunLoopGetMain(),
    AXObserverGetRunLoopSource(observer),
    .defaultMode
)
```

通知はMainに届く。通知の受信自体は軽い（ブロックしない）ので問題ない。**通知ハンドラ内で同期AX呼び出しをしないこと**が唯一の注意点。属性が必要なら PIDキューへ投げて非同期に取得する。

### 6.6 HotkeyManager

**採用: Carbon `RegisterEventHotKey`**

理由:
- CGEventTap より軽量。全キーイベントを流さないのでCPUコストが原理的にゼロに近い
- 入力監視（Input Monitoring）権限が不要
- OSレベルでホットキーが横取りされるため、他アプリのキー処理に干渉しない

```swift
import Carbon.HIToolbox

func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> EventHotKeyRef? {
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x574D_4B59 /* "WMKY" */), id: id)
    let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    return status == noErr ? ref : nil
}
```

修飾キー定数（Carbon）:

| 修飾キー | 定数 | 値 |
|---|---|---|
| Command | `cmdKey` | 0x0100 |
| Shift | `shiftKey` | 0x0200 |
| Option (Alt) | `optionKey` | 0x0800 |
| Control | `controlKey` | 0x1000 |

**制約**: `RegisterEventHotKey` は「修飾キー + 単一キー」のみ。i3の `mode`（修飾キーなしの連打）を実装するには、モード中だけ `CGEventTap` を有効化する必要がある。§9.4 参照。

**キーコード**: `kVK_ANSI_1` (0x12) 〜 `kVK_ANSI_0` (0x1D)、`kVK_ANSI_H` (0x04) など。設定TOMLの文字列（`"alt-shift-h"`）からキーコードへのマッピングテーブルを用意する。JIS配列でも**仮想キーコードは配列に依存しない**ので、記号キー（`;` = `kVK_ANSI_Semicolon` = 0x29、`/` = `kVK_ANSI_Slash` = 0x2C）はそのまま使える。

### 6.7 MonitorManager

```swift
@MainActor
final class MonitorManager {
    private(set) var monitors: [Monitor] = []

    func start() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, ...
        ) { _ in self.reconfigure() }
    }

    private func reconfigure() {
        // 1. モニタ一覧を再取得
        // 2. 消えたモニタに割り当てられていたワークスペースをメインモニタへ移す
        // 3. 退避座標を再計算（union矩形が変わるため）
        // 4. engine.reconcile()
    }
}
```

**1画面運用でも必須の理由**: 外部モニタを付け替えると解像度・union矩形・プライマリの高さがすべて変わる。**退避座標が画面内に入り込むと、非表示ワークスペースのウィンドウが突然出現する。** 再構成時の退避座標再計算は必ず実装すること。

`didChangeScreenParametersNotification` は解像度変更中に複数回発火するため、**200ms程度のデバウンス**をかける。

---

## 7. 主要アルゴリズム

### 7.1 focus（方向フォーカス移動）

```
focus(direction):
  axis = (direction == .left || direction == .right) ? .horizontal : .vertical
  forward = (direction == .right || direction == .down)

  node = currentFocusedWindowNode
  while node.parent != nil:
      parent = node.parent
      if parent.orientation == axis:
          idx = parent.children.indexOf(node)
          nextIdx = forward ? idx + 1 : idx - 1
          if parent.children.indices.contains(nextIdx):
              target = descendToLeaf(parent.children[nextIdx], preferring: direction)
              focusWindow(target.windowID)
              return
      node = parent

  // ツリー内に対象がない → 隣接モニタへ移動を試みる（1画面運用では何もしない）
```

**`descendToLeaf`**: コンテナに降りるとき、どの葉を選ぶか。
- **推奨: 最終フォーカス時刻が最も新しい葉**（`lastFocusedAt` 最大）。i3の挙動に近く、直感的。
- 代替: 進入方向に対して幾何的に最も近い葉。

**フォーカスの実行**

```swift
// PIDキュー上で実行
func focusWindow(_ element: AXUIElement, pid: pid_t) {
    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    // アプリ自体をアクティブにしないとキー入力が届かない
    NSRunningApplication(processIdentifier: pid)?.activate()
}
```

`NSRunningApplication.activate()` はMainから呼ぶ必要がある。AX部分をPIDキュー、`activate()` をMainに分ける。

> `activate(options:)` の `.activateIgnoringOtherApps` は macOS 14 で非推奨。macOS 26 では引数なしの `activate()` を使う。

### 7.2 move（ウィンドウの移動）

```
move(direction):
  axis, forward = 同上
  node = currentFocusedWindowNode

  while node.parent != nil:
      parent = node.parent
      if parent.orientation == axis:
          idx = parent.children.indexOf(node)
          nextIdx = forward ? idx + 1 : idx - 1

          if parent.children.indices.contains(nextIdx):
              sibling = parent.children[nextIdx]
              if sibling is ContainerNode:
                  // 隣がコンテナ → その中へ入る
                  parent.remove(node)
                  sibling.insert(node, at: forward ? 0 : sibling.children.count)
              else:
                  // 隣がウィンドウ → 位置を入れ替える
                  parent.children.swapAt(idx, nextIdx)
                  parent.weights.swapAt(idx, nextIdx)
              normalize(); reconcile(); return
      node = parent

  // 最上位まで到達 → ルートの orientation を跨いだ移動として、ルート直下の端へ移す
```

### 7.3 resize

```
resize(dimension, delta):   // dimension: .width | .height, delta: pt
  axis = (dimension == .width) ? .horizontal : .vertical
  node = currentFocusedWindowNode

  // 対象軸のコンテナを親方向に探す
  container = nearestAncestor(node, orientation: axis)
  guard container != nil else { return }

  idx = container.indexOfChild(containing: node)
  totalLength = (axis == .horizontal) ? containerRect.width : containerRect.height
  deltaRatio = delta / totalLength

  // 自分を増やし、隣接する子から同量を減らす
  neighbor = (idx + 1 < container.children.count) ? idx + 1 : idx - 1
  container.weights[idx]      += deltaRatio
  container.weights[neighbor] -= deltaRatio

  clampWeights(container, min: 0.05)   // 潰れ防止
  reconcile()
```

**重要**: この処理は**メモリ操作のみ**でマイクロ秒で終わる。AX適用は `reconcile()` → `scheduler.submit()` 経由でコアレスされる。これが症状Bの解決である。

### 7.4 ワークスペース切替（症状Cの実装）

```
switchWorkspace(to: target):
  if target == activeWorkspace: return

  previousWorkspace = activeWorkspace
  outgoing = workspaces[activeWorkspace]
  incoming = workspaces[target]

  // 1. 離脱側のフォーカスを保存
  outgoing.lastFocused = currentFocusedWindowID

  // 2. 壁紙を即座に切り替える（Main、非同期API、待たない）
  wallpaperService.apply(for: target)

  // 3. インジケータ更新（Main、即座）
  indicator.update(to: target)

  // 4. 目標フレームを一括計算
  var targets: [CGWindowID: CGRect] = [:]
  var sizeDirty: Set<CGWindowID> = []

  //    4-a. 表示側（先に積む）
  let area = monitor(for: incoming).visibleFrame
  let computed = LayoutEngine.compute(root: incoming.root, area: area, gaps: config.gaps)
  for (id, rect) in computed {
      targets[id] = rect
      if incoming.layoutDirty { sizeDirty.insert(id) }   // レイアウト不変ならサイズ設定を省略
  }
  incoming.layoutDirty = false

  //    4-b. 退避側（後に積む）
  let stash = stashOrigin()   // union矩形の外側
  for id in outgoing.allWindowIDs {
      targets[id] = CGRect(origin: stash, size: .zero)  // sizeは使わない
      // sizeDirty には入れない → setPosition のみ = IPC 1回
  }

  // 5. 一括投入。scheduler が PID ごとに並列展開する
  scheduler.submit(targets, sizeDirty: sizeDirty)

  activeWorkspace = target

  // 6. フォーカス復元
  let toFocus = incoming.lastFocused ?? incoming.firstWindowID
  if let f = toFocus { focusWindow(f) } else { clearFocusBorder() }

  // 7. フォーカス枠線は目標フレームへ即座に移動（AXの完了を待たない）
  decoration.moveBorder(to: computed[toFocus])
```

**`stashOrigin()` の算出**

```swift
func stashOrigin() -> CGPoint {
    // 全モニタのunion矩形（AX座標系）
    let union = monitors.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    // 十分に外側。負値だとアプリ側でクランプされることがあるので正方向へ逃がす
    return CGPoint(x: union.minX, y: union.maxY + 100_000)
}
```

**`layoutDirty` の管理**: 以下の場合に `true` を立てる。
- そのワークスペースのツリーが変更された（ウィンドウの追加/削除/移動/リサイズ）
- モニタ構成が変わった
- gaps設定が変わった

非アクティブ中に何も起きていなければ `false` のまま → 復帰時は position のみ = **IPC 1回/ウィンドウ**。

**同一ワークスペース内のウィンドウが同一アプリに固まっている場合**、並列度が上がらない。これは原理的な限界。ただしその場合ウィンドウ数自体が少ないことが多く、実害は小さい。

### 7.5 フォーカス管理

**WMが持つフォーカス状態と、OSの実際のフォーカスがずれる問題**への対処。

- WMは `focusedWindowID` を保持する
- `kAXFocusedWindowChangedNotification` / `NSWorkspace.didActivateApplicationNotification` を受けたら、OS側の実態に合わせて `focusedWindowID` を更新する（**WMの意図で上書きしない**）
- ただし、WM自身がフォーカス変更を発行した直後（100ms以内）の通知は自分の操作の反響なので無視してよい（`expectedFocus` を持って照合）

**ワークスペース切替でフォーカス先が無い場合**: `clearFocusBorder()` を呼び、枠線を消す。「フォーカスがどこにもない」状態を視覚的に明示する。

### 7.6 ディスプレイ付け替え

```
onScreenParametersChanged (200ms デバウンス後):
  1. monitors を再取得
  2. 各ワークスペースの monitor 割り当てを検証
     - 割り当て先が消えていたら main へ再割り当て
  3. stashOrigin を再計算
  4. 全ワークスペースの layoutDirty = true
  5. 非アクティブワークスペースのウィンドウを新しい退避座標へ移動（重要）
  6. reconcile()
```

手順5を忘れると、**退避中のウィンドウが新しい画面配置の中に現れる**。

---

## 8. 内蔵UI

### 8.1 ワークスペースインジケータ

**方式: メニューバー常駐（`NSStatusItem`）+ 切替時のHUD**

```swift
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "1"
// クリック無効（表示専用）にするなら button?.isEnabled = false
```

HUD版（切替時に画面中央へ一瞬表示して消える）を併設する場合:
- `NSWindow`（borderless, `.statusBar` level, `ignoresMouseEvents = true`）
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`
- 表示 → 400ms 保持 → 200ms フェードアウト
- 連続切替時は前のHUDを即座に差し替える（アニメーションをキャンセル）
- `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` が `true` ならフェードを省略

設定で `menubar` / `hud` / `both` / `off` を選べるようにする。

### 8.2 フォーカス枠線

**方式: 透過オーバーレイ `NSWindow`**

macOSでは他プロセスのウィンドウの枠自体を変更できないため、フォーカス中ウィンドウの矩形にぴったり重なる透過ウィンドウを1枚置き、その縁だけを描画する。

```swift
let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
w.isOpaque = false
w.backgroundColor = .clear
w.hasShadow = false
w.ignoresMouseEvents = true
w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

// 縁だけ描く: contentView のレイヤに枠線
let layer = CALayer()
layer.borderWidth = config.border.width
layer.borderColor = config.border.colorFocused.cgColor
layer.cornerRadius = config.border.radius
layer.backgroundColor = NSColor.clear.cgColor
```

**枠線の位置更新（体感上の要点）**

- **AXの適用完了を待たず、目標フレームが決まった時点で即座に動かす。** 枠線は自プロセスのウィンドウなので数十マイクロ秒で動く
- 結果として「枠線が先に着地し、ウィンドウがそれに収まる」ように見え、**遅延が視覚的に隠蔽される**
- ウィンドウ側が目標に届かなかった場合（アプリの最小サイズ制約など）は、`observedFrame` を受けて枠線を実測値に合わせ直す

**枠線とウィンドウの重なり**: 枠線ウィンドウをウィンドウ矩形と**同一**にすると、対象ウィンドウの内容に枠が被る。`width` 分だけ外側に広げる（`insetBy(dx: -width, dy: -width)`）と、ギャップの中に枠が描かれて自然になる。gaps が 5pt なら border width 2pt が収まる。

### 8.3 壁紙

```swift
@MainActor
final class WallpaperService {
    private var urls: [WorkspaceID: URL] = [:]

    func apply(for workspace: WorkspaceID) {
        guard let url = urls[workspace] else { return }   // 未設定なら何もしない
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }
}
```

- 起動時に設定からURLマップを読み、**ファイルの実在を検証**しておく（存在しないパスは無視）
- `setDesktopImageURL` は内部で非同期に処理されるため、呼び出し自体は即座に返る
- ワークスペース切替の最初期（ウィンドウ移動の発行前）に呼ぶ

**macOS 26 での検証項目**（§12.5）:
1. `setDesktopImageURL` が実際に壁紙を変えるか
2. 変更が「設定 > 壁紙」に反映されるか（されなくても実害はない）
3. 連続呼び出し（高速なワークスペース切替）でクラッシュ・レートリミットが無いか

---

## 9. 設定仕様

### 9.1 ファイル配置

| パス | 内容 |
|---|---|
| `~/.config/comet/config.toml` | メイン設定。home-manager から生成 |

**ホットリロード**: `DispatchSourceFileSystemObject`（またはFSEvents）で監視する。

> **注意**: home-manager 管理下ではファイルは**Nixストアへのシンボリックリンク**であり、`home-manager switch` 時にはリンク先が差し替わる（ファイル自体は書き換わらない）。**リンク自体の変更を検知する必要があるため、親ディレクトリ `~/.config/comet/` を監視対象にする**（現行のHammerspoon設定が `hs.pathwatcher` でディレクトリを見ているのと同じ理由）。

リロード時の挙動:
- ホットキーを全解除 → 再登録
- gaps / border / 壁紙マップを更新
- 全ワークスペースを `layoutDirty = true` にして `reconcile()`
- **ツリー構造は保持する**（設定変更でレイアウトが崩れないこと）

### 9.2 設定ファイル全体像

```toml
# ~/.config/comet/config.toml

start-at-login = true

[normalization]
flatten-containers          = true    # 子1つのコンテナを潰す
opposite-orientation-nested = true    # 入れ子コンテナは親と逆向き

[layout]
default-orientation = "auto"          # "auto" | "horizontal" | "vertical"
                                      # auto = 領域が横長なら horizontal

[gaps]
inner-horizontal = 5
inner-vertical   = 5
outer-top        = 5
outer-bottom     = 5
outer-left       = 5
outer-right      = 5

[workspaces]
count = 10

[wallpaper]
enabled = true
# ワークスペース番号 → 画像パス。未設定のワークスペースでは壁紙を変更しない
[wallpaper.map]
1 = "~/Pictures/wallpapers/wallpaper1.jpg"
2 = "~/Pictures/wallpapers/wallpaper2.jpg"
3 = "~/Pictures/wallpapers/wallpaper3.jpg"
4 = "~/Pictures/wallpapers/wallpaper4.jpg"
5 = "~/Pictures/wallpapers/wallpaper5.jpg"

[border]
enabled        = true
width          = 2.0
radius         = 10.0
color-focused  = "#7aa2f7"
# color-unfocused を設定すると全タイルに枠を描く（未設定ならフォーカスのみ）

[indicator]
enabled   = true
style     = "both"      # "menubar" | "hud" | "both" | "off"
hud-duration-ms = 400

[performance]
ax-timeout-ms          = 100   # AXメッセージングタイムアウト
apply-interval-ms      = 8     # FrameScheduler のティック間隔
disable-enhanced-ui    = true  # AXEnhancedUserInterface の一時無効化
max-correction-retries = 3     # 目標とずれた場合の補正回数上限

[debug]
timing = false          # 適用レイテンシのログ出力（§11）
log-level = "info"      # "trace" | "debug" | "info" | "warn" | "error"

# ---- キーバインド ----
[mode.main.binding]
# §9.3 に全量

# ---- ウィンドウルール ----
[[window-rule]]
if-app-id = "com.apple.systempreferences"
run       = "layout floating"

[[window-rule]]
if-app-id = "com.apple.finder"
run       = "layout floating"
```

### 9.3 キーバインド移植表

現行AeroSpaceの全バインドを移植する。**コマンド文字列はAeroSpace互換にしておくと移行時の設定書き換えが不要。**

```toml
[mode.main.binding]
# -- ワークスペース切替 --
alt-1 = "workspace 1"
alt-2 = "workspace 2"
alt-3 = "workspace 3"
alt-4 = "workspace 4"
alt-5 = "workspace 5"
alt-6 = "workspace 6"
alt-7 = "workspace 7"
alt-8 = "workspace 8"
alt-9 = "workspace 9"
alt-0 = "workspace 10"

# -- ウィンドウをワークスペースへ移動して追従 --
alt-shift-1 = ["move-node-to-workspace 1", "workspace 1"]
alt-shift-2 = ["move-node-to-workspace 2", "workspace 2"]
alt-shift-3 = ["move-node-to-workspace 3", "workspace 3"]
alt-shift-4 = ["move-node-to-workspace 4", "workspace 4"]
alt-shift-5 = ["move-node-to-workspace 5", "workspace 5"]
alt-shift-6 = ["move-node-to-workspace 6", "workspace 6"]
alt-shift-7 = ["move-node-to-workspace 7", "workspace 7"]
alt-shift-8 = ["move-node-to-workspace 8", "workspace 8"]
alt-shift-9 = ["move-node-to-workspace 9", "workspace 9"]
alt-shift-0 = ["move-node-to-workspace 10", "workspace 10"]

# -- フォーカス移動 --
alt-h = "focus left"
alt-j = "focus down"
alt-k = "focus up"
alt-l = "focus right"

# -- ウィンドウ移動 --
alt-shift-h = "move left"
alt-shift-j = "move down"
alt-shift-k = "move up"
alt-shift-l = "move right"

# -- リサイズ --
alt-ctrl-h = "resize width -50"
alt-ctrl-j = "resize height +50"
alt-ctrl-k = "resize height -50"
alt-ctrl-l = "resize width +50"

# -- その他 --
alt-semicolon = "fullscreen"
alt-s         = "move-node-to-monitor next"
alt-a         = "move-node-to-monitor main"
alt-slash     = "layout tiles horizontal vertical"
alt-shift-f   = "layout floating tiling"
alt-e         = "join-with right"
alt-w         = "join-with down"
```

**新規追加を推奨するバインド**

| バインド | コマンド | 理由 |
|---|---|---|
| `alt-shift-delete` | `close-window` | Hammerspoon側の同機能を移管（§2.3） |
| `alt-tab` | `workspace back-and-forth` | 直前ワークスペースへのトグル |
| `alt-r` | `mode resize` | リサイズモード（§9.4）。症状Bへの追加対策 |

### 9.4 モード（リサイズモード）

i3の `mode` 相当。修飾キーなしの `h/j/k/l` 連打を可能にする。

**実装**: `RegisterEventHotKey` は修飾キーなしのキーを登録できない（登録できてもグローバルに奪ってしまい他アプリで文字が打てなくなる）。したがって:

```
mode resize に入る:
  1. CGEventTap を作成・有効化（.keyDown をリッスン）
  2. HUDに "RESIZE" を表示
  3. h/j/k/l → resize コマンド、イベントは消費する（return nil）
  4. Esc / Enter / alt-r → モード終了、EventTap を無効化
  5. それ以外のキーも消費する（誤爆防止）
```

**権限**: `CGEventTap` には「入力監視（Input Monitoring）」権限が必要。**モードを使わない限りEventTapを作らない**設計にすれば、権限を要求せずに基本機能を使える。

**タイムアウト**: 3秒間キー入力がなければ自動的にモードを抜ける（モードに入ったまま気づかず操作不能になる事故を防ぐ）。

**優先度**: モードは Phase 5 以降の実装で構わない。まずは `alt-ctrl-hjkl` のコアレスで症状Bが解消するか確認する。

### 9.5 コマンド一覧

| コマンド | 引数 | 動作 |
|---|---|---|
| `workspace` | `1..10` \| `back-and-forth` | ワークスペース切替 |
| `move-node-to-workspace` | `1..10` | フォーカス中ウィンドウを移動 |
| `focus` | `left\|down\|up\|right` | 方向フォーカス |
| `move` | `left\|down\|up\|right` | ウィンドウを方向へ移動 |
| `resize` | `width\|height ±N` | リサイズ |
| `fullscreen` | — | モニタいっぱいにタイル配置（トグル） |
| `layout` | `tiles horizontal vertical` | 親コンテナのorientation切替（引数を巡回） |
| `layout` | `floating tiling` | float/tile切替 |
| `join-with` | `left\|down\|up\|right` | 隣接ウィンドウと新コンテナを作る |
| `move-node-to-monitor` | `next\|main` | モニタ間移動 |
| `close-window` | — | ウィンドウを閉じる（`kAXCloseButtonAttribute` → press） |
| `mode` | モード名 | モード遷移 |
| `reload-config` | — | 設定再読込 |

**複数コマンドの配列指定**（`alt-shift-1 = ["move-node-to-workspace 1", "workspace 1"]`）は**1回の `reconcile()` にまとめる**。中間状態を適用しないことで、ウィンドウ移動+切替が1フレームで完了する。

---

## 10. プロジェクト構成

### 10.1 ディレクトリ

```
comet/
├── Package.swift
├── DESIGN.md                       # 本書
├── README.md
├── Sources/
│   ├── comet/
│   │   └── main.swift              # エントリポイント、権限チェック、起動
│   ├── CometCore/
│   │   ├── Engine.swift
│   │   ├── FrameScheduler.swift
│   │   ├── State/
│   │   │   ├── Tree.swift          # Node / WindowNode / ContainerNode
│   │   │   ├── Normalization.swift
│   │   │   ├── Workspace.swift
│   │   │   ├── WindowRegistry.swift
│   │   │   └── MonitorManager.swift
│   │   ├── Layout/
│   │   │   ├── LayoutEngine.swift  # 純粋関数。テストの主対象
│   │   │   └── Geometry.swift      # 座標変換・丸め
│   │   └── Commands/
│   │       ├── Command.swift       # コマンドのパースと表現
│   │       ├── FocusCommand.swift
│   │       ├── MoveCommand.swift
│   │       ├── ResizeCommand.swift
│   │       └── WorkspaceCommand.swift
│   ├── CometAccessibility/
│   │   ├── AXPrivate.swift         # _AXUIElementGetWindow 等の宣言
│   │   ├── AXBridge.swift          # 読み書きのラッパ（バッチ読み込み含む）
│   │   ├── AXObserverHub.swift
│   │   ├── ApplierPool.swift
│   │   └── AppRegistry.swift       # PID ↔ AXUIElement(app) の管理
│   ├── CometInput/
│   │   ├── HotkeyManager.swift
│   │   ├── KeyCode.swift           # "alt-shift-h" → (keyCode, modifiers)
│   │   └── ModeController.swift    # CGEventTap（Phase 5+）
│   ├── CometDecoration/
│   │   ├── DecorationController.swift
│   │   ├── FocusBorder.swift
│   │   ├── WorkspaceIndicator.swift
│   │   └── WallpaperService.swift
│   └── CometConfig/
│       ├── Config.swift            # Codable な設定モデル
│       ├── ConfigLoader.swift
│       └── ConfigWatcher.swift
└── Tests/
    └── CometCoreTests/
        ├── LayoutEngineTests.swift
        ├── NormalizationTests.swift
        ├── TreeCommandTests.swift
        └── GeometryTests.swift
```

### 10.2 依存

| パッケージ | 用途 | 備考 |
|---|---|---|
| [TOMLDecoder](https://github.com/dduan/TOMLDecoder) | TOMLパース | Codable対応。SPM。純Swift |

Swift標準にTOMLパーサは無い。依存を増やしたくない場合は必要最小限のサブセットパーサを自作する選択肢もあるが、設定の表現力を落とすため**外部パッケージを推奨**。

### 10.3 ビルドと配布

**アプリバンドルが必要な理由**: Accessibility権限は**コード署名の同一性**に紐づく。素の実行ファイルを再ビルドするたびに権限が外れて再許可が必要になり、開発が著しく面倒になる。

```
comet.app/
└── Contents/
    ├── Info.plist          # LSUIElement = true（Dockに出さない）
    └── MacOS/
        └── comet
```

**Info.plist の要点**

```xml
<key>LSUIElement</key><true/>              <!-- Dock非表示、メニューバーのみ -->
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleIdentifier</key><string>local.comet</string>
```

**署名**: 開発中は ad-hoc 署名（`codesign -s - --force --deep comet.app`）で十分だが、**ad-hoc署名はビルドごとにハッシュが変わり権限が外れる**。安定させるには自己署名証明書を作ってそれで署名し続けるのが確実。

```bash
# 一度だけ: キーチェーンアクセスで「コード署名」用の自己署名証明書 "comet-dev" を作成
codesign -s "comet-dev" --force --options runtime comet.app
```

**ログイン起動**: `SMAppService.mainApp.register()`（macOS 13+）。設定 `start-at-login = true` のときに呼ぶ。

**nixとの統合**: Swiftのビルドをnixで再現するのは負担が大きい。**設定ファイル（`~/.config/comet/config.toml`）だけをhome-managerで管理し、バイナリは手動ビルド + `~/Applications` 配置**とするのが現実的。将来的にnix化する場合も、この分離があれば移行しやすい。

### 10.4 起動シーケンス

```
main.swift:
  1. Accessibility権限チェック
       AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])
       → false なら案内を表示して終了（またはポーリングして許可を待つ）
  2. 設定読み込み（失敗したらデフォルト設定で起動し、エラーを通知）
  3. AXUIElementSetMessagingTimeout をシステムワイド要素に設定
  4. MonitorManager 起動
  5. 既存ウィンドウの列挙とツリー構築（§10.5）
  6. AXObserverHub 起動（全既存アプリ + 起動監視）
  7. HotkeyManager 起動
  8. Decoration 起動
  9. ConfigWatcher 起動
 10. NSApplication.run()
```

### 10.5 既存ウィンドウの初期列挙

起動時、すでに開いているウィンドウをツリーに取り込む。

```
for app in NSWorkspace.shared.runningApplications:
    guard app.activationPolicy == .regular else { continue }   // メニューバー常駐アプリ等を除外
    appElement = AXUIElementCreateApplication(app.processIdentifier)
    windows = appElement[kAXWindowsAttribute]                  // PIDキュー上で
    for w in windows:
        attrs = batchRead(w)                                   // 1往復で全属性
        if isManageable(attrs): register(w)
```

**配属先の決定**: 起動時にどのワークスペースへ割り当てるか。
- **推奨: 全ウィンドウをワークスペース1に集約する。** 単純で予測可能
- 代替: 現在の画面上の位置から推測（複雑で不確実。採らない）

**状態の永続化は行わない。** WM再起動時にワークスペース配置が失われるが、実装が単純になり、状態不整合のリスクが消える。必要になったら後で追加する（`~/.local/state/comet/session.json` 等）。

---

## 11. 検証

### 11.1 単体テスト（LayoutEngine / Tree）

副作用の無い層はテストで固める。ここが壊れると全体が壊れる。

```swift
// LayoutEngineTests
func testHorizontalSplitEqualWeights()
func testGapsAppliedBetweenSiblingsOnly()      // 外周ギャップと内側ギャップの区別
func testNestedContainerAreaSum()              // 全矩形の合計が area - gaps に一致
func testLastChildAbsorbsRoundingError()       // 累積誤差で隙間が出ない
func testSingleWindowFillsAreaMinusOuterGaps()

// NormalizationTests
func testSingleChildContainerIsFlattened()
func testNestedContainerGetsOppositeOrientation()
func testEmptyContainerIsRemoved()
func testWeightsAlwaysSumToOne()

// TreeCommandTests
func testFocusRightMovesToSibling()
func testFocusRightAscendsWhenNoSibling()
func testMoveSwapsSiblings()
func testMoveIntoAdjacentContainer()
func testResizeAdjustsOnlyTwoWeights()
func testResizeClampsAtMinimum()

// GeometryTests
func testAXToAppKitRoundTrip()
func testCoordinateConversionWithMultipleDisplays()
```

### 11.2 手動検証チェックリスト（症状の解消確認）

数値目標は置かないが、**症状が消えたかを毎フェーズで確認する**。

| # | 検証項目 | 手順 | 合格条件 |
|---|---|---|---|
| A-1 | 新規ウィンドウのちらつき | WezTermを既存2ウィンドウのワークスペースで新規起動 | デフォルト位置に見えない、またはほぼ知覚できない |
| A-2 | 同上（重いアプリ） | Chromeで新規ウィンドウ | 同上 |
| B-1 | リサイズ連打 | `alt-ctrl-l` を2秒間押しっぱなし | 押している間ずっと滑らかに追従し、離した瞬間に止まる |
| B-2 | リサイズ往復 | `alt-ctrl-l` と `alt-ctrl-h` を交互に連打 | 位置が飛ばない、遅れて動き続けない |
| C-1 | ワークスペース切替 | ウィンドウ4枚のWS1 ↔ 3枚のWS2 を往復 | ウィンドウが1枚ずつ現れない、瞬時に完成して見える |
| C-2 | 高速切替 | `alt-1` 〜 `alt-5` を素早く連打 | 追従する、壁紙が遅れない、フォーカスが失われない |
| C-3 | フォーカス復元 | WS1でウィンドウBにフォーカス → WS2 → WS1 | ウィンドウBにフォーカスが戻る |
| D-1 | 壁紙 | ワークスペースを切り替える | ウィンドウの再配置と同時に壁紙が変わる |
| E-1 | ハングアプリ耐性 | 重い処理でアプリを固まらせ、その状態でWM操作 | 他のウィンドウの操作が問題なくできる |
| E-2 | モニタ付け替え | 外部モニタを接続 → 切断 | 非表示ワークスペースのウィンドウが画面に現れない |
| E-3 | 常駐コスト | 無操作で10分放置 | CPU使用率がほぼ0%、メモリが増え続けない |

### 11.3 計測機構（debug時のみ）

数値目標は置かないが、「遅い気がする」を切り分けるために計測は用意する。

```swift
// config: [debug] timing = true のとき
struct TimingLog {
    // AX適用のレイテンシをアプリ別に集計
    // 出力例:
    // [timing] setPosition  pid=1234 (Google Chrome)   p50=3.2ms p95=18.4ms p99=52.1ms n=428
    // [timing] setSize      pid=5678 (WezTerm)         p50=0.8ms p95=2.1ms  p99=3.9ms  n=428
    // [timing] workspace-switch  1→2  windows=7 apps=4  wall=11.3ms
}
```

**これがあると「どのアプリが足を引っ張っているか」が即座に分かる。** 症状が再発したときの調査コストが桁で変わるので、早い段階で入れる価値がある。

---

## 12. リスクと対策

### 12.1 AeroSpaceとの同時起動

**両方が同時に動くと、互いのウィンドウ配置を上書きし合って発振する。** 開発中は必ず片方だけを動かす。

```bash
# 開発時
osascript -e 'quit app "AeroSpace"'   # または launchctl でアンロード
```

移行が完了するまで、AeroSpaceの `start-at-login = true` を切り、手動起動に切り替えておくと事故が減る。

### 12.2 private シンボルの消失

`_AXUIElementGetWindow` はOSアップデートで消える可能性がある（実績としては長期間安定しているが保証はない）。

**対策**: `@_silgen_name` による直接リンクは、シンボルが無いと**起動時にリンクエラーでクラッシュする**。`dlsym` による動的解決に切り替え、無ければフォールバック（`CGWindowListCopyWindowInfo` でPIDとフレームから推定）できるようにする。

```swift
typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

let axGetWindow: AXGetWindowFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: AXGetWindowFn.self)
}()
```

### 12.3 Hammerspoonとの機能重複

現行の `Alt+F`（次のアプリへフォーカス）/ `Alt+D`（同一アプリの次ウィンドウ）は、Hammerspoonが `hs.window.filter` で独自にウィンドウ一覧を保持して動く。WMも同じ情報を持つため二重管理になる。

**当面は共存させる**（実害は小さい）。ただし以下に注意:
- `Alt+F` でフォーカスが変わると、WM側は `kAXFocusedWindowChangedNotification` でそれを検知して追従する必要がある（§7.5）。**これが正しく動くことをC-3で確認すること**
- 将来的にはWM側の `focus next-app` / `focus next-window-in-app` として実装し、Hammerspoonから外すのが望ましい

### 12.4 ウィンドウ操作を拒否するアプリ

一部のアプリはAXでのリサイズ・移動を無視する、または独自に位置を補正する。

**対策**: §6.4 の補正リトライ（上限3回）→ それでも一致しなければ自動的に `floating` へ降格し、ログに残す。ユーザーはそのアプリを `window-rule` で明示的に floating にすればよい。

### 12.5 `setDesktopImageURL` が macOS 26 で機能しない場合

**フォールバック順**:
1. `NSWorkspace.setDesktopImageURL`（第一候補）
2. 壁紙用のフルスクリーン透過ウィンドウを最背面（`CGWindowLevelForKey(.desktopIconWindow) - 1`）に置き、そこに画像を描く。**OSの壁紙機能を使わずWM側で完全に制御する。** 切替は自プロセスの描画なので確実に高速
3. `osascript` へのフォールバック（現状維持、最後の手段）

**選択肢2は実は最も速く確実**である。OSの壁紙設定を汚さない利点もある。第一候補が macOS 26 で不安定なら、迷わず2へ移る。

### 12.6 「画面外退避」の副作用

- **スクリーンショット（Cmd+Shift+3 の全画面）に退避ウィンドウは写らない**（画面外なので）。問題なし
- **画面録画・画面共有**でも同様に写らない
- ただし **Cmd+Tab / Mission Control / Dockのウィンドウ一覧には全ウィンドウが出る。** これは方式上避けられない。Cmd+Tabで非表示ワークスペースのアプリを選ぶと、そのウィンドウが画面外にあるままアクティブになり「アプリは前面だがウィンドウが見えない」状態になる
  - **対策**: `kAXApplicationActivatedNotification` を受けたとき、そのアプリのウィンドウが非アクティブワークスペースにあれば、**そのワークスペースへ自動的に切り替える**。i3の `focus_follows_activation` 相当。実装は容易で体験が大きく改善する。**Phase 4 で入れることを推奨**

### 12.7 Accessibility権限の再取得

再ビルドのたびに権限が外れると開発効率が落ちる。§10.3 の自己署名証明書で回避する。それでも外れた場合:

```bash
# TCCデータベースから該当エントリを削除（要再許可）
tccutil reset Accessibility local.comet
```

---

## 13. 実装フェーズ

各フェーズは**動作確認可能な状態で完了する**こと。

### Phase 0 — 基盤（1〜2日）

- [ ] SPMプロジェクト作成、アプリバンドル化、自己署名の手順確立
- [ ] Accessibility権限チェックと案内
- [ ] ログ基盤（レベル別、`os.Logger` 推奨）
- [ ] `AXPrivate.swift`（`dlsym` 版 `_AXUIElementGetWindow`）
- [ ] `ApplierPool`（PIDごとのキュー）
- [ ] Carbon ホットキー登録（ハードコードで1つだけ、動作確認用）

**完了条件**: ホットキーを押すとログが出る。権限が正しく取得できている。

### Phase 1 — ウィンドウ検出と単純配置（2〜3日）

- [ ] `AppRegistry` / `WindowRegistry`
- [ ] `AXObserverHub`（window created / destroyed / focus changed）
- [ ] バッチ属性読み込み（`AXUIElementCopyMultipleAttributeValues`）
- [ ] 管理対象判定
- [ ] `MonitorManager`、座標変換（`Geometry.swift`）
- [ ] `FrameScheduler`（コアレス機構を**この時点で**入れる）
- [ ] 単純な等分割配置（ツリーなし、横に均等）

**完了条件**: ウィンドウを開くと自動的に等分割でタイルされる。閉じると再配置される。

> **注意**: `FrameScheduler` をここで入れること。「後で入れる」を選ぶと Phase 3 以降で全面改修になる（§4.2）。

### Phase 2 — BSPツリーとコマンド（3〜4日）

- [ ] `Tree.swift`（Node / Container / Window）
- [ ] `Normalization.swift`
- [ ] `LayoutEngine.swift` + **単体テスト**
- [ ] focus / move / resize / join-with / layout コマンド
- [ ] 設定ファイル読み込み（TOML）とホットキーの設定駆動化
- [ ] ウィンドウルール（floating指定）

**完了条件**: `alt-hjkl` / `alt-shift-hjkl` / `alt-ctrl-hjkl` / `alt-e` / `alt-w` / `alt-slash` / `alt-shift-f` が現行AeroSpaceと同等に動く。**症状B（リサイズ連打）がこの時点で解消していること。**

### Phase 3 — ワークスペース（2〜3日）

- [ ] `Workspace` モデル、10ワークスペース
- [ ] 画面外退避、`stashOrigin` 計算
- [ ] `workspace` / `move-node-to-workspace` コマンド
- [ ] `layoutDirty` によるサイズ設定の省略
- [ ] フォーカス保存・復元
- [ ] `back-and-forth`

**完了条件**: `alt-1..0` / `alt-shift-1..0` が動く。**症状C（切替の遅さ）がこの時点で解消していること。** 検証 C-1〜C-3 を通す。

### Phase 4 — 高速化の詰めと堅牢性（2〜3日）

- [ ] `AXEnhancedUserInterface` の一時無効化
- [ ] メッセージングタイムアウト設定
- [ ] 補正リトライと自動floating降格
- [ ] 新規ウィンドウの最優先適用（症状A）
- [ ] `focus_follows_activation`（§12.6）
- [ ] 計測機構（`[debug] timing`）
- [ ] ディスプレイ付け替えハンドリング

**完了条件**: 検証 A-1, A-2, E-1, E-2, E-3 を通す。

### Phase 5 — 内蔵UI（2〜3日）

- [ ] `WallpaperService`（+ 必要なら §12.5 の方式2）
- [ ] `FocusBorder`
- [ ] `WorkspaceIndicator`（メニューバー + HUD）

**完了条件**: 検証 D-1 を通す。フォーカス位置が常に一目で分かる。

### Phase 6 — 常用化（1〜2日）

- [ ] 設定ホットリロード（ディレクトリ監視）
- [ ] `SMAppService` によるログイン起動
- [ ] `close-window` コマンド、Hammerspoon側の該当バインド削除
- [ ] home-manager での設定ファイル管理
- [ ] AeroSpaceの停止・アンインストール
- [ ] README（セットアップ手順、必須システム設定一覧）

**完了条件**: 再起動後、何もせずに常用できる状態。

### Phase 7 以降（任意）

- リサイズモード（§9.4）
- スクラッチパッド
- タブ/スタックレイアウト
- レイアウト構造の可視化HUD
- セッション永続化

---

## 14. 実装時の注意点（チェックリスト）

実装中に繰り返し確認すべき事項。

- [ ] **Mainスレッドで同期AX呼び出しをしていないか。** 1箇所でもあれば台無しになる
- [ ] `reconcile()` を状態変更のたびに呼んでいるか。呼び忘れると画面が更新されない
- [ ] 木を変更したあと `normalize()` を呼んでいるか
- [ ] `weights` の合計が1.0に保たれているか（浮動小数の累積誤差に注意）
- [ ] 座標系を混同していないか（内部は常にAX座標系 = top-left）
- [ ] `primaryMaxY` をキャッシュしていないか（モニタ付け替えで変わる）
- [ ] AXUIElementではなくCGWindowIDを主キーにしているか
- [ ] アプリ終了時にPIDキューとAXObserverを破棄しているか（リーク防止）
- [ ] ウィンドウ破棄時にツリーから除去し、空コンテナを畳んでいるか
- [ ] WM自身が発行したフォーカス変更の反響を無限ループさせていないか
- [ ] 補正リトライに上限があるか
- [ ] アイドル時にFrameSchedulerのティックが止まっているか（常駐CPUコスト）

---

## 15. 参考資料

| 資料 | 内容 |
|---|---|
| [AeroSpace](https://github.com/nikitabobko/AeroSpace) | 置き換え対象。Swift製。BSPツリー・画面外退避方式の実装参考 |
| [yabai](https://github.com/koekeishiya/yabai) | C製。AX APIの使い方、`AXEnhancedUserInterface` ワークアラウンド、SkyLight利用（SIP無効側） |
| [Rectangle](https://github.com/rxhanson/Rectangle) | Swift製。`AXEnhancedUserInterface` の扱い、ウィンドウ移動の実践的な知見 |
| Apple: Accessibility API Reference | `AXUIElement.h` / `AXUIElementCopyMultipleAttributeValues` の仕様 |
| Apple: Carbon Event Manager | `RegisterEventHotKey` |
| i3 User's Guide | ツリーモデル、コマンド体系、mode の仕様 |

---

## 付録A: 現行環境の実測情報

```
macOS       : 26.5.2 (Build 25F84)
CPU         : Apple M4
SIP         : enabled
Display     : Built-in Liquid Retina, 2560 x 1664, Main
稼働中WM    : AeroSpace, Hammerspoon
設定管理    : nix + home-manager
              ~/.aerospace.toml      → /nix/store/.../
              ~/.hammerspoon/        → /nix/store/.../
              ~/.config/aerospace/   → /nix/store/.../
```

## 付録B: 現行Hammerspoonバインド一覧（衝突確認用）

WMのホットキーと衝突しないよう、実装前に確認すること。

| バインド | 機能 | WMとの関係 |
|---|---|---|
| `alt-f` | 次のアプリへフォーカス | §12.3 参照。当面共存 |
| `alt-d` | 同一アプリの次ウィンドウ | 同上 |
| `cmd-shift-v` | クリップボード履歴 | 衝突なし |
| `cmd-space` | アプリ検索 | 衝突なし |
| `cmd-alt-shift-t/f/b/k` | アプリ起動 | 衝突なし |
| `cmd-alt-shift-space` | Claude起動 | 衝突なし |
| `cmd-alt-shift-delete` | ウィンドウを閉じる | **WMへ移管推奨**（§2.3） |
| `cmd-alt-shift-return` | MagicBoardトグル | 衝突なし |
| `cmd-alt-shift-w` | スニペット | 衝突なし |
| `ctrl-alt-r` | Hammerspoonリロード | 衝突なし |

**注意**: `alt-f` / `alt-d` は AeroSpace の `alt-*` 系と同じ修飾キー空間にある。WM側で `alt-f` / `alt-d` を使わないこと。
