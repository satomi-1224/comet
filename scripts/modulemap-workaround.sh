# ホストのツールチェーンに壊れた module.modulemap が残っている場合の回避。
#
# 一部の Mac には `<toolchain>/usr/include/swift/module.modulemap`（Xcode 15 期の残骸）が
# 残っており、同じディレクトリの `bridging.modulemap` と同じ `SwiftBridging` を定義している。
# こうなると **`import Foundation` を含む一切のコンパイルが冷えた状態から通らない**。
# 出るのは「redefinition of module 'SwiftBridging'」と、それに続く
# 「this SDK is not supported by the compiler」という誤解を招く二次エラー。
# `.build` が温まっている間は通ってしまうので、気づくのは大抵ビルドし直したとき。
#
# 恒久的な直し方は残骸を退かすことだが sudo が要る:
#     sudo mv <toolchain>/usr/include/swift/module.modulemap{,.disabled}
#
# ここでは sudo なしで済ませるため、VFS overlay で当該ファイルを**空**に見せる。
# 二重定義を検出したときだけ効かせるので、健全な環境では何もしない。
#
# `scripts/env.sh`（swift build / swift test）と `nix/package.nix`（Nix ビルド）の
# 両方から使う。**bash 3.2 でも動くように書くこと**（macOS の /bin/bash は 3.2）。
#
# 必要な変数:
#   developerDir   ツールチェーンの場所（xcode-select -p の出力）
#   workaroundDir  生成物を置く場所
# 設定する変数:
#   COMET_OVERLAY_FLAGS  swift build / swift test へそのまま渡す配列（空のことがある）
#   SWIFT_EXEC_MANIFEST  SwiftPM のマニフェスト評価に噛ませるラッパ（環境変数）

COMET_OVERLAY_FLAGS=()

_comet_stale_map="$developerDir/usr/include/swift/module.modulemap"
_comet_bridging_map="$developerDir/usr/include/swift/bridging.modulemap"

if [ -f "$_comet_stale_map" ] && [ -f "$_comet_bridging_map" ] &&
  grep -q 'module SwiftBridging' "$_comet_stale_map" &&
  grep -q 'module SwiftBridging' "$_comet_bridging_map"; then

  echo "==> $_comet_stale_map が SwiftBridging を二重定義している。VFS overlay で空にして回避する" >&2
  echo "    恒久対応: sudo mv $_comet_stale_map{,.disabled}" >&2

  mkdir -p "$workaroundDir"
  : > "$workaroundDir/empty.modulemap"
  cat > "$workaroundDir/vfs-overlay.yaml" <<OVERLAY
{
  "version": 0,
  "case-sensitive": false,
  "use-external-names": false,
  "roots": [
    {
      "type": "directory",
      "name": "$developerDir/usr/include/swift",
      "contents": [
        {
          "type": "file",
          "name": "module.modulemap",
          "external-contents": "$workaroundDir/empty.modulemap"
        }
      ]
    }
  ]
}
OVERLAY

  COMET_OVERLAY_FLAGS=(-Xswiftc -vfsoverlay -Xswiftc "$workaroundDir/vfs-overlay.yaml")

  # SwiftPM は Package.swift の評価にも swiftc を使う。そこへは -Xswiftc が届かないので、
  # SWIFT_EXEC_MANIFEST でラッパを噛ませる。
  #
  # **-vfsoverlay は引数の最後に置くこと。** SwiftPM 自身が Package.swift を写すための
  # -vfsoverlay を渡しており、先に置くとそちらに負けて効かない（実測）。
  cat > "$workaroundDir/swiftc-manifest-wrapper" <<WRAPPER
#!/bin/bash
exec "$developerDir/usr/bin/swiftc" "\$@" -vfsoverlay "$workaroundDir/vfs-overlay.yaml"
WRAPPER
  chmod +x "$workaroundDir/swiftc-manifest-wrapper"
  export SWIFT_EXEC_MANIFEST="$workaroundDir/swiftc-manifest-wrapper"
fi

unset _comet_stale_map _comet_bridging_map
