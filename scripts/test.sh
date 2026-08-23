#!/bin/bash
# テスト実行。`swift test` の代わりにこれを使う。
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

# bash 3.2 + set -u では空配列の展開がエラーになるため要素数で分岐する。
FLAGS=()
if [ ${#COMET_TEST_FLAGS[@]} -gt 0 ]; then FLAGS+=("${COMET_TEST_FLAGS[@]}"); fi
if [ ${#COMET_OVERLAY_FLAGS[@]} -gt 0 ]; then FLAGS+=("${COMET_OVERLAY_FLAGS[@]}"); fi

if [ ${#FLAGS[@]} -gt 0 ]; then
  exec swift test "${FLAGS[@]}" "$@"
else
  exec swift test "$@"
fi
