#!/bin/bash
# comet.app を組み立てる。
#
# アクセシビリティ権限はコード署名の同一性に紐づくため、素の実行ファイルではなく
# .app バンドルにして安定した署名を与える必要がある（設計書 §10.3）。
#
# 使い方: ./scripts/build-app.sh [debug|release]

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

CONFIGURATION="${1:-release}"
SIGNING_IDENTITY="comet-dev"
BUNDLE_ID="local.comet"

echo "==> ビルド ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

# --show-bin-path が進捗行を混ぜて出すことがあるので最終行だけ取る。
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path | tail -1)/comet"
if [ ! -x "$BIN_PATH" ]; then
  echo "実行ファイルが見つからない: $BIN_PATH" >&2
  exit 1
fi

APP="$REPO_ROOT/build/comet.app"
echo "==> バンドル組み立て: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$REPO_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_PATH" "$APP/Contents/MacOS/comet"

echo "==> 署名"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGNING_IDENTITY\""; then
  codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "    署名 ID: $SIGNING_IDENTITY（権限はビルドをまたいで維持される）"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  cat <<'MSG'
    署名 ID: ad-hoc

    警告: ad-hoc 署名はビルドのたびにハッシュが変わるため、
    再ビルドするとアクセシビリティ権限が外れて再許可が必要になる。
    ./scripts/make-signing-cert.sh で固定の署名 ID を作ると回避できる。
MSG
fi

echo "==> 完了: $APP"
echo "    起動: open $APP           （常駐。終了は ctrl-alt-shift-q）"
echo "    前景: $APP/Contents/MacOS/comet  （ログが端末に出る。終了は Ctrl-C）"
