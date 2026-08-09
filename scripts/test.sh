#!/bin/bash
# テスト実行。`swift test` の代わりにこれを使う。
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

# bash 3.2 + set -u では空配列の展開がエラーになるため要素数で分岐する。
if [ ${#COMET_TEST_FLAGS[@]} -gt 0 ]; then
  exec swift test "${COMET_TEST_FLAGS[@]}" "$@"
else
  exec swift test "$@"
fi
