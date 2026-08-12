{ config, lib, pkgs, ... }:

let
  cfg = config.programs.comet;
  tomlFormat = pkgs.formats.toml { };
  hasSettings = cfg.settingsFile != null || cfg.settings != { };
in
{
  options.programs.comet = {
    enable = lib.mkEnableOption "comet（macOS 向けのタイリングウィンドウマネージャ）";

    app = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Applications/comet.app";
      description = ''
        comet.app の場所。

        **Nix ストアには置かないこと。** アクセシビリティ権限はアプリの同一性に
        紐づくため、更新のたびにパスが変わると権限が外れて確認ダイアログが出る。
        リポジトリの `./scripts/install-app.sh` が既定でこの場所へ入れる。

        Swift 6 が要るため nixpkgs の Swift（5.10）ではビルドできない。
        このモジュールが受け持つのは**設定・自動起動・ログの置き場所**だけ。
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
      default = "${config.home.homeDirectory}/Library/Logs/comet.log";
      description = "launchd から起動したときのログの出力先。";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "programs.comet は macOS でのみ使える。";
      }
    ];

    # 設定を書いていないときは置かない。空の TOML を置くと
    # キーバインドが1つも登録されない状態になる。
    home.file.".config/comet/config.toml" = lib.mkIf hasSettings {
      source =
        if cfg.settingsFile != null then
          cfg.settingsFile
        else
          tomlFormat.generate "comet-config.toml" cfg.settings;
    };

    launchd.agents.comet = lib.mkIf cfg.startService {
      enable = true;
      config = {
        ProgramArguments = [ "${cfg.app}/Contents/MacOS/comet" ];
        RunAtLoad = true;
        # 理由不明で落ちたときに上げ直す。
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardOutPath = cfg.logFile;
        StandardErrorPath = cfg.logFile;
      };
    };

    # **アプリの実体は Nix の管理外**なので、無ければここで気づけるようにする。
    home.activation.cometApp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -x "${cfg.app}/Contents/MacOS/comet" ]; then
        warnEcho "comet.app が ${cfg.app} に無い。リポジトリで ./scripts/install-app.sh release を実行する"
      fi
    '';
  };
}
