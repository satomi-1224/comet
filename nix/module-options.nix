# home-manager モジュールと nix-darwin モジュールで共有する選択肢の定義。
#
# 綴りと既定値を1か所に置くのは、両方から同じ名前で書けるようにするため。
# 実際の適用（設定ファイルの配置・launchd の登録）はそれぞれのモジュールで行う。
{
  lib,
  pkgs,
  # `~` の展開先。home-manager では config.home.homeDirectory、
  # nix-darwin では対象ユーザのホーム。
  homeDirectory,
  # このリポジトリの flake が渡す comet パッケージ。flake 経由でなければ null。
  defaultPackage ? null,
}:

let
  tomlFormat = pkgs.formats.toml { };
in
{
  enable = lib.mkEnableOption "comet（macOS 向けのタイリングウィンドウマネージャ）";

  package = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = defaultPackage;
    defaultText = lib.literalExpression "comet.packages.\${system}.comet";
    description = ''
      導入する comet のパッケージ。

      `null` にすると**本体は Nix の管理外**になり、`app` に置いてあるものを
      そのまま使う（`./scripts/install-app.sh` で入れた場合など）。
      設定と自動起動だけを Nix で持ちたいときに使う。
    '';
  };

  app = lib.mkOption {
    type = lib.types.str;
    default = "${homeDirectory}/Applications/comet.app";
    description = ''
      comet.app を置く場所。

      **ストアから直接動かさない。** アクセシビリティ権限はコード署名の同一性に
      紐づくが、ストアの中では ad-hoc 署名しかできず、内容が変わるたびに
      cdhash が変わって権限が外れる。ここへ写してから固定の署名 ID
      （`signingIdentity`）で署名し直すことで、更新しても権限を保てる。

      `package` が `null` のときは、写す元が無いので**既にここにあるもの**を使う。
    '';
  };

  signingIdentity = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = "comet-dev";
    description = ''
      `app` へ写したあと署名し直すのに使うコード署名 ID。

      この ID はキーチェーンに要る。`./scripts/make-signing-cert.sh` が作る。
      無ければ ad-hoc 署名のままになり、**更新のたびにアクセシビリティ権限を
      付け直す**ことになる（動作はする）。

      `null` にすると署名し直さない。
    '';
  };

  startService = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      launchd agent として登録し、ログイン時に起動する。

      comet 自身にも `start-at-login` があるが、**launchd 側で持つほうが宣言的で、
      落ちたときに上げ直せる**。二重登録を避けるため、こちらを使うなら
      設定の `start-at-login` は false のままにしておく。
    '';
  };

  settings = lib.mkOption {
    type = tomlFormat.type;
    default = { };
    example = lib.literalExpression ''
      {
        gaps.inner-horizontal = 7;
        gaps.outer-top = 7;
        border.color-focused = "#7aa2f7";
        wallpaper.dir = "~/Pictures/wallpapers";
        mode.main.binding = {
          alt-h = "focus left";
          alt-l = "focus right";
        };
      }
    '';
    description = ''
      `~/.config/comet/config.toml` の内容。

      comet は保存を検知して**自動で読み直す**ので、switch すればそのまま反映される
      （ツリーの形とワークスペースの状態は保たれる）。

      既定値の一覧は `comet --print-default-config` で出せる。
      **キーバインドは置き換えになる**（既定へ追加されるのではない）ので、
      書くときは必要なものを全部書く。
    '';
  };

  settingsFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    example = lib.literalExpression "./config.toml";
    description = ''
      既に書いてある `config.toml` をそのまま置く。`settings` より優先する。
      TOML を Nix の属性集合へ書き直したくない場合に使う。
    '';
  };

  logFile = lib.mkOption {
    type = lib.types.str;
    default = "${homeDirectory}/Library/Logs/comet.log";
    description = "launchd から起動したときのログの出力先。";
  };
}
