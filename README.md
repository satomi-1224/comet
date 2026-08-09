# comet

macOS 向けのタイリングウィンドウマネージャ。AeroSpace + Hammerspoon の2プロセス構成を、
Swift 製の単一プロセスに置き換えることを目的とする。

設計の全体像・性能問題の分析・実装フェーズは [DESIGN.md](DESIGN.md) を参照。

## 現在の状態

**Phase 0（基盤）完了。** ホットキーを押すとログが出るところまで。
ウィンドウ操作はまだ実装していない。

## 必要なもの

- macOS 14 以降（開発環境は 26.5.2 で検証）
- Swift 6.0 以降（Command Line Tools のみで可。Xcode は不要）

Xcode を入れていない場合、SPM は `Testing.framework` を自動では見つけられない。
`scripts/env.sh` が探索パスと rpath を補うので、テストは `swift test` ではなく
`./scripts/test.sh` を使うこと。

## 使い方

```bash
# テスト
./scripts/test.sh

# .app を組み立てる（アクセシビリティ権限に必要）
./scripts/build-app.sh release

# 前景で起動。ログが端末に出る。終了は Ctrl-C か ctrl-alt-shift-q
build/comet.app/Contents/MacOS/comet --log-level debug

# 常駐起動。ログは統一ログへ
open build/comet.app
log stream --predicate 'subsystem == "local.comet"'
```

### オプション

| オプション | 内容 |
|---|---|
| `--log-level <level>` | `trace` / `debug` / `info` / `warn` / `error` / `off`。既定は `info` |
| `--hotkey <spec>` | 登録するホットキー。複数回指定可。省略時は `ctrl-alt-shift-{h,j,k,l}` |
| `--print-keys` | 指定できるキー名を一覧表示 |
| `--help` | ヘルプ |

ホットキーの書式は `alt-shift-h` のように修飾キーとキーをハイフンで連ねる。
修飾キーは `cmd` / `alt` / `ctrl` / `shift`（別名 `command` / `opt` / `option` / `control`）。
`-` 自体をキーに指定するときは `minus` と綴る。

## 初回セットアップ

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
  comet/                エントリポイント
scripts/
  env.sh             共通ビルド環境（CLT 向けの探索パス補正）
  test.sh            テスト実行
  build-app.sh       .app の組み立てと署名
  make-signing-cert.sh  開発用署名 ID の作成
```
