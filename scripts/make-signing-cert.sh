#!/bin/bash
# 開発用の自己署名コード署名証明書 "comet-dev" を作る。一度だけ実行すればよい。
#
# なぜ必要か:
#   アクセシビリティ権限はコード署名の同一性に紐づく。ad-hoc 署名（codesign -s -）は
#   ビルドのたびに cdhash が変わるため、再ビルドすると権限が外れて再許可を求められる。
#   固定の署名 ID で署名し続ければ権限は維持される（設計書 §10.3, §12.7）。
#
# 注意:
#   キーチェーンへの登録と信頼設定でパスワード入力を求められる。
#   GUI で行う場合は「キーチェーンアクセス > 証明書アシスタント > 証明書を作成」で
#   名前 comet-dev / 証明書のタイプ「コード署名」/ 自己署名ルート を選んでも同じ。

set -euo pipefail

IDENTITY="comet-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "署名 ID \"$IDENTITY\" は既に存在する。何もしない。"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 鍵と証明書を生成"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

openssl pkcs12 -export -out "$WORK/$IDENTITY.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:

echo "==> キーチェーンに登録（パスワードを求められる）"
security import "$WORK/$IDENTITY.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

echo "==> 信頼設定（パスワードを求められる）"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  cat <<'MSG'
完了。以降 ./scripts/build-app.sh はこの ID で署名する。

次の2点に注意:

1. 初回の codesign でキーチェーンのアクセス許可ダイアログが出る。
   「常に許可」を選ぶこと。「許可」を選ぶとビルドのたびに聞かれる。

2. 署名 ID が変わるため、既に付与済みのアクセシビリティ権限を一度リセットする:
       tccutil reset Accessibility local.comet
MSG
else
  echo "署名 ID を作成できなかった。キーチェーンアクセスの GUI から作成すること。" >&2
  exit 1
fi
