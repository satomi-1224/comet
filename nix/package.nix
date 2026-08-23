# comet.app を Nix で組む。
#
# **Swift 6 が要る。** nixpkgs の Swift は 5.10 なので、コンパイラだけはホストの
# Command Line Tools（または Xcode）を借りる。そのため `__noChroot = true` を付けて
# サンドボックスの外でビルドする。借りるのはコンパイラと macOS SDK だけで、
# ソースと依存パッケージはすべてストアから来る（ビルド中にネットワークへ出ない）。
#
# 出力:
#   $out/Applications/comet.app  本体
#   $out/bin/comet               上のバンドル内の実行ファイルへの symlink。
#                                `comet --send` / `--query` を使うとき用。
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  runCommandLocal,

  # flake からは self が渡る。
  src,

  # `release` か `debug`。
  configuration ? "release",

  # ストアの中では固定の署名 ID を使えない（キーチェーンに触れない）ので ad-hoc で署名する。
  # 権限を保つための固定 ID での署名は導入時（home-manager / nix-darwin の activation）に行う。
  bundleIdentifier ? "local.comet",

  # ホストのツールチェーンを探す場所。xcode-select の設定を使うのが既定。
  developerDir ? null,
}:

let
  # Info.plist を版番号の単一の出所にする。Nix 側に版番号を書かないので食い違わない。
  # `src` から読むこと（リポジトリからの相対で読むと、`src` を差し替えたときにずれる）。
  plist = builtins.readFile "${src}/Resources/Info.plist";
  plistLines = lib.splitString "\n" plist;
  versionIndex = lib.lists.findFirstIndex
    (l: lib.hasInfix "CFBundleShortVersionString" l) null plistLines;
  version =
    assert lib.assertMsg (versionIndex != null)
      "Resources/Info.plist に CFBundleShortVersionString が無い";
    lib.head (builtins.match ".*<string>(.*)</string>.*"
      (lib.elemAt plistLines (versionIndex + 1)));

  # SwiftPM の依存をストアから与える。**Package.resolved と手で揃える。**
  # 揃っていなければ下の substituteInPlace が --replace-fail で落ちるので、
  # 黙って古い版が使われることはない。
  #
  # ここで `.package(url:)` を `.package(path:)` へ書き換える。ディレクトリ名が
  # そのままパッケージの識別子になるため、**取り込み先の名前を Package.swift の
  # `package:` と同じ綴りにする**こと。
  swiftDependencies = [
    {
      name = "TOMLDecoder";
      declaration = ''.package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5")'';
      source = fetchFromGitHub {
        owner = "dduan";
        repo = "TOMLDecoder";
        rev = "a2bbd2796fe3064e107de18cb56031052c4fa899"; # 0.4.5
        hash = "sha256-sazDC5JH+7v0S/ER0TeI5fAPpMj5tbyxYKiNxvsP5aE=";
      };
    }
  ];

  vendorDir = ".nix-deps";

  vendorCommands = lib.concatMapStringsSep "\n" (dep: ''
    cp -R ${dep.source} "${vendorDir}/${dep.name}"
    chmod -R u+w "${vendorDir}/${dep.name}"
    substituteInPlace Package.swift \
      --replace-fail ${lib.escapeShellArg dep.declaration} \
        '.package(path: "${vendorDir}/${dep.name}")'
  '') swiftDependencies;
in

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "comet";
  inherit version src;

  # nixpkgs の Swift（5.10）では組めないので、ホストのツールチェーンへ届く必要がある。
  __noChroot = true;

  # fixup を通すと strip と rpath 書き換えでコード署名が壊れる。
  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    # ビルドに使う道具は /usr/bin から取る。PATH の**末尾**に足すこと。
    # 先頭に置くと BSD 版の coreutils が nixpkgs のものを覆って
    # stdenv のフック（substituteInPlace 等）が壊れる。
    export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
    export HOME="$NIX_BUILD_TOP/home"
    mkdir -p "$HOME"

    developerDir=${if developerDir != null then lib.escapeShellArg developerDir
                   else "\"$(/usr/bin/xcode-select -p)\""}
    export DEVELOPER_DIR="$developerDir"
    export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

    echo "toolchain: $developerDir"
    "$developerDir/usr/bin/swift" --version

    # scripts/ と同じ回避を使う（実装を1か所に置くため）。developerDir は上で設定済み。
    workaroundDir="$NIX_BUILD_TOP/modulemap-workaround"
    ${builtins.readFile ../scripts/modulemap-workaround.sh}

    echo "==> 依存をストアから取り込む"
    mkdir -p "${vendorDir}"
    ${vendorCommands}
    # 取り込んだ先はローカルパス依存なので解決結果は要らない。残すと
    # 「remoteSourceControl の固定が残っている」と食い違う。
    rm -f Package.resolved

    echo "==> ビルド (${configuration})"
    "$developerDir/usr/bin/swift" build \
      --configuration ${configuration} \
      --disable-sandbox \
      --scratch-path "$NIX_BUILD_TOP/spm" \
      --cache-path "$NIX_BUILD_TOP/spm-cache" \
      --product comet \
      "''${COMET_OVERLAY_FLAGS[@]}"

    "$developerDir/usr/bin/swift" build \
      --configuration ${configuration} \
      --disable-sandbox \
      --scratch-path "$NIX_BUILD_TOP/spm" \
      --cache-path "$NIX_BUILD_TOP/spm-cache" \
      --show-bin-path | tail -1 > "$NIX_BUILD_TOP/bin-path"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    binDir="$(cat "$NIX_BUILD_TOP/bin-path")"
    app="$out/Applications/comet.app"

    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/bin"
    install -m 644 Resources/Info.plist "$app/Contents/Info.plist"
    install -m 755 "$binDir/comet" "$app/Contents/MacOS/comet"
    install -m 644 Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

    # ad-hoc 署名。ストアの中ではこれ以上のことはできない。
    # 固定 ID での署名は導入時に行う（nix/install-app.sh）。
    /usr/bin/codesign --force --sign - --identifier ${lib.escapeShellArg bundleIdentifier} "$app"

    # `comet --send` / `--query` を PATH から使えるようにする。
    # **バンドルの中を指すこと。** 素の実行ファイルを別に置くと、
    # アクセシビリティ権限の同一性がバンドルと食い違う。
    ln -s "$app/Contents/MacOS/comet" "$out/bin/comet"

    runHook postInstall
  '';

  passthru = {
    inherit bundleIdentifier;
    # 導入先や activation から参照する。
    appPath = "Applications/comet.app";

    # PATH へ入れる用。`comet --send` / `--query`（i3-msg 相当）だけを出す。
    #
    # **パッケージそのものを PATH へ入れてはならない。** home-manager と nix-darwin は
    # `Applications/` を拾って `~/Applications/Home Manager Apps` や `/Applications/Nix Apps`
    # へ並べる。ストアの中は ad-hoc 署名なので、そちらを起動されると別の同一性として
    # 扱われ、アクセシビリティ権限を改めて求められる。
    cli = runCommandLocal "comet-cli" { } ''
      mkdir -p "$out/bin"
      ln -s ${finalAttrs.finalPackage}/bin/comet "$out/bin/comet"
    '';
  };

  meta = {
    description = "macOS 向けのタイリングウィンドウマネージャ";
    homepage = "https://github.com/satomi-1224/comet";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "comet";
  };
})
