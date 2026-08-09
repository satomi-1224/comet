# 実装進捗

> 最終更新: 2026-08-09
> 設計の全体像は [DESIGN.md](DESIGN.md)、使い方は [README.md](README.md)

## 進め方の規約

各 Phase は以下のループが**一巡してはじめて完了**とする。

```
テスト作成 → 実装 → 敵対レビュー → 修正 → 敵対レビュー → 修正
```

- テストは実装より先に書く。コンパイルが通らない red 状態を必ず経由する。
- 敵対レビューは「動くこと」ではなく「壊れ方」を探す。見つけた欠陥は
  深刻度とともに本ファイルに記録し、再発したときに気づけるようにする。
- Phase の完了条件は DESIGN.md §13 に定義済み。**症状 A〜D の解消が最終的な判定基準**であり、
  機能が揃ったことは完了条件ではない。

## 全体

| Phase | 内容 | 状態 | 完了条件 |
|---|---|---|---|
| 0 | 基盤 | **完了** | ホットキーを押すとログが出る / 権限が取れている |
| 1 | ウィンドウ検出と単純配置 | 未着手 | ウィンドウを開くと自動でタイルされ、閉じると再配置される |
| 2 | BSPツリーとコマンド | 未着手 | 現行 AeroSpace と同等に動く / **症状B解消** |
| 3 | ワークスペース | 未着手 | alt-1..0 が動く / **症状C解消** |
| 4 | 高速化の詰めと堅牢性 | 未着手 | **症状A解消** / ハングアプリ耐性 |
| 5 | 内蔵UI | 未着手 | **症状D解消** / フォーカス位置が一目で分かる |
| 6 | 常用化 | 未着手 | 再起動後そのまま常用できる |
| 7+ | 拡張 | 未着手 | 症状が解消してから着手する |

### 潰すべき4症状（プロジェクトの成否判定）

| | 症状 | 解消予定 |
|---|---|---|
| A | 新規ウィンドウがデフォルト位置に一瞬出てから飛ぶ | Phase 4 |
| B | リサイズ連打で追従しない・飛ぶ・戻る | Phase 2 |
| C | ワークスペース切替が遅い・ちらつく | Phase 3 |
| D | 壁紙変更がワンテンポ遅れる | Phase 5 |

---

## Phase 0 — 基盤 【完了】

### 成果物

| モジュール | 内容 |
|---|---|
| `CometSupport` | `LogLevel` / `Log`（stderr + 統一ログ、`@autoclosure` で無効時ゼロコスト）/ `LaunchOptions` / `SingleInstanceLock` |
| `CometInput` | `Hotkey` / `KeySpec`（`"alt-shift-h"` のパーサ）/ `HotkeyManager`（Carbon `RegisterEventHotKey`） |
| `CometAccessibility` | `AXPrivate`（`dlsym` 版 `_AXUIElementGetWindow`）/ `ApplierPool`（PIDごとの直列キュー）/ `AXPermission` |
| `comet` | エントリポイント |
| `scripts/` | `env.sh` / `test.sh` / `build-app.sh` / `make-signing-cert.sh` |

テスト **81件 / 7スイート**。

### 完了条件の検証結果

合成 `CGEvent` でキーを送出して自動検証した（手押しに依存しない）。

| 検証 | 結果 |
|---|---|
| ホットキー押下 → ログ | `ホットキー発火: alt-ctrl-shift-h` → `押下: alt-ctrl-shift-h` |
| アクセシビリティ権限 | 起動時に正しく検出 |
| `_AXUIElementGetWindow` 解決 | 成功（macOS 26.5.2 でシンボル健在） |
| 二重起動の拒否 | 2つ目が `exit=1` でロックエラー |
| 終了ホットキー | `ctrl-alt-shift-q` で正常終了、ロック解放 |
| ロック解放後の再起動 | 成功 |

### 敵対レビューで修正した欠陥

**1回目**

| 深刻度 | 欠陥 | 対処 |
|---|---|---|
| 高 | `HotkeyManager.start()` が Carbon に `passUnretained(self)` を渡していた。マネージャ解放後にキーが押されると**解放済みメモリを参照**する | `passRetained` + 明示的な `stop()` |
| 高 | `start()` を呼ばずに `register()` すると `RegisterEventHotKey` は成功してキーをシステム全体から奪う一方、配送先が無い。**そのキーだけ無反応**になる | `notStarted` で拒否 |
| 高 | bash 3.2 + `set -u` で**空配列展開が unbound variable エラー**（実測確認） | 要素数で分岐 |
| 中 | `fail()` が stderr のみ。`open` 起動時は stderr が消えるため**致命エラーが不可視** | 統一ログにも出し、`--log-level off` でも致命エラーは抑制しない |
| 低 | `--log-level=` が「不正なログレベル: 」という中身のない診断になる | 欠落として扱う |
| 低 | `HotkeyManager` にテストが1件も無い | Carbon に触れない経路のテストを追加 |

**2回目**

| 深刻度 | 欠陥 | 対処 |
|---|---|---|
| 中 | **二重起動を検知できない**。残留インスタンスがホットキーを掴んでいると「AeroSpace が原因」と誤診断する | `flock(2)` ベースの `SingleInstanceLock` を追加 |
| 中 | キーコード表に重複があっても**無言で上書き**され、`description` が別のキー名を返すようになる | 全キーの `description` 往復テストを追加 |
| 低 | `make-signing-cert.sh` が partition list を設定せず、署名のたびにキーチェーンのダイアログが出る | 「常に許可」を選ぶ案内を追加 |

---

## Phase 1 — ウィンドウ検出と単純配置 【未着手】

### やること

- `AppRegistry` / `WindowRegistry`
- `AXObserverHub`（window created / destroyed / focus changed）
- バッチ属性読み込み（`AXUIElementCopyMultipleAttributeValues` で**1往復**）
- 管理対象判定（role / subrole / フルスクリーン / 最小化 / 極小ウィンドウ）
- `MonitorManager`、座標変換（AppKit 左下原点 ↔ AX 左上原点）
- **`FrameScheduler`（コアレス機構）**
- 単純な等分割配置（ツリーはまだ入れない）

### 着手前に確定していること

- **`FrameScheduler` は Phase 1 で入れる。** 後回しにすると Phase 3 以降で全面改修になる（DESIGN.md §4.2, §13）。
- **メインスレッドで同期 AX 呼び出しをしない。** AX 呼び出しは対象アプリの都合で最大6秒ブロックしうる。
  AX へのアクセスは `ApplierPool` が返す PID ごとのキュー上でのみ行う。
- 内部座標は全て **CG/AX 座標系（左上原点）** で保持し、AppKit に渡す直前だけ変換する。
  変換に使うプライマリの高さは**キャッシュしない**（モニタ付け替えで変わる）。
- ウィンドウの主キーは `AXUIElement` ではなく **`CGWindowID`**。

### 検証項目

| # | 内容 |
|---|---|
| 1 | ウィンドウを開くと自動的に等分割でタイルされる |
| 2 | 閉じると残りが再配置される |
| 3 | ダイアログ・ポップオーバーがタイルされない |
| 4 | 重いアプリ（Chrome 等）がハングしても他のウィンドウが操作できる |
| 5 | 無操作時に `FrameScheduler` のティックが止まっている（常駐CPUコスト） |

---

## 環境で判明した制約

| 事項 | 内容 |
|---|---|
| **Xcode 未インストール** | Command Line Tools のみ。`xcodebuild` は使えないが SPM ビルドと手動バンドル化で足りる |
| **`Testing.framework` の探索** | CLT 内にあるが SPM が自動で見つけない。`scripts/env.sh` が `-F` と rpath 2本を補う。テストは **`./scripts/test.sh`** を使う（`swift test` 直叩きは失敗する） |
| **`XCTest.framework` は無い** | CLT に同梱されていない。テストは Swift Testing 一本 |
| **`/bin/bash` は 3.2** | `set -u` のもとで空配列の `"${arr[@]}"` 展開がエラーになる。`${#arr[@]}` で分岐すること |
| **署名 ID が未作成** | 現在 ad-hoc 署名のため**再ビルドのたびにアクセシビリティ権限が外れる**。`./scripts/make-signing-cert.sh` を一度実行すると解消（キーチェーンのパスワード入力が必要なため手動） |
| **AeroSpace が稼働中** | 開発中は停止しないとホットキーとウィンドウ配置を奪い合う。Phase 0 の既定バインドを `ctrl-alt-shift-*` にしているのはこのため |

## 未決事項

| 事項 | 判断が必要な時期 |
|---|---|
| `~/Pictures/wallpapers/` の実在（現行 `wallpaper_config.sh` が5枚を参照しているが未確認） | Phase 5 |
| macOS 26 で `NSWorkspace.setDesktopImageURL` が期待通り動くか。ダメなら最背面に自前の壁紙ウィンドウを置く方式へ | Phase 5 |
| Hammerspoon の `alt-f` / `alt-d`（アプリ・ウィンドウ巡回）を comet 側へ移すか | Phase 6 |
