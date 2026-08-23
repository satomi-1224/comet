# comet の home-manager モジュール。本体・設定・自動起動をまとめて宣言する。
#
# 使い方は README の「Nix で使う」を見ること。
#
#   nix flake update comet && home-manager switch
#
# で更新まで完結する（本体を組み直し、`app` へ入れ替え、launchd を上げ直す）。
# flake が `self.packages` を渡す。system ごとに解決するのはここ。
{ cometPackages ? null }:

{ config, lib, pkgs, ... }:

let
  defaultPackage =
    if cometPackages == null then
      null
    else
      cometPackages.${pkgs.stdenv.hostPlatform.system}.comet or null;

  cfg = config.programs.comet;
  tomlFormat = pkgs.formats.toml { };
  hasSettings = cfg.settingsFile != null || cfg.settings != { };

  # home-manager が launchd.agents.<name> に付けるラベル。
  label = "org.nix-community.home.comet";
in
{
  options.programs.comet = import ./module-options.nix {
    inherit lib pkgs defaultPackage;
    homeDirectory = config.home.homeDirectory;
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "programs.comet は macOS でのみ使える。";
      }
    ];

    # `comet --send` / `--query` を PATH から使えるようにする（i3-msg 相当）。
    # 常駐する本体は `app` に置いたほうで、これは問い合わせ用の入口。
    # `.cli` を使うのは `Applications/` を含めないため（passthru.cli の注記を見ること）。
    home.packages = lib.optional (cfg.package != null) (cfg.package.cli or cfg.package);

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

    # 本体をストアから `app` へ入れ替える。
    #
    # **writeBoundary の直後に置くこと。** home-manager が launchd を触る
    # setupLaunchAgents より前に走らせたい。plist が変わらない更新（本体だけ
    # 新しくなった場合）では home-manager は agent を上げ直さないので、
    # 入れ替えたこちらが bootout/bootstrap まで面倒を見る。
    home.activation.cometApp = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      if cfg.package != null then
        ''
          COMET_SOURCE_APP=${lib.escapeShellArg "${cfg.package}/Applications/comet.app"} \
          COMET_DESTINATION=${lib.escapeShellArg cfg.app} \
          COMET_SIGNING_IDENTITY=${lib.escapeShellArg (toString cfg.signingIdentity)} \
          COMET_LAUNCHD_LABEL=${lib.escapeShellArg (lib.optionalString cfg.startService label)} \
          COMET_STATE_DIR=${lib.escapeShellArg "${config.home.homeDirectory}/Library/Application Support/comet"} \
          run ${pkgs.bash}/bin/bash ${./install-app.sh}
        ''
      else
        # **本体が Nix の管理外**の場合。無ければここで気づけるようにする。
        ''
          if [ ! -x ${lib.escapeShellArg "${cfg.app}/Contents/MacOS/comet"} ]; then
            warnEcho "comet.app が ${cfg.app} に無い。programs.comet.package を設定するか、リポジトリで ./scripts/install-app.sh release を実行する"
          fi
        ''
    );
  };
}
