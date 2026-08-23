# comet の nix-darwin モジュール。home-manager を使っていない構成向け。
#
# **home-manager を使っているなら `homeManagerModules.comet` のほうを使うこと。**
# あちらは activation が利用者のセッションで走るため、キーチェーンの署名 ID を
# 使った署名し直しが確実に通る。こちらは activation が root で走り、`sudo -u` で
# 利用者へ降りるので、環境によってはキーチェーンに届かず ad-hoc 署名のままになる
# （動作はするが、更新のたびにアクセシビリティ権限を付け直すことになる）。
# その場合は端末から一度だけ `nix run github:satomi-1224/comet#install` を実行する。
# flake が `self.packages` を渡す。system ごとに解決するのはここ。
{ cometPackages ? null }:

{ config, lib, pkgs, ... }:

let
  defaultPackage =
    if cometPackages == null then
      null
    else
      cometPackages.${pkgs.stdenv.hostPlatform.system}.comet or null;

  cfg = config.services.comet;
  tomlFormat = pkgs.formats.toml { };
  hasSettings = cfg.settingsFile != null || cfg.settings != { };

  configFile =
    if cfg.settingsFile != null then
      cfg.settingsFile
    else
      tomlFormat.generate "comet-config.toml" cfg.settings;

  # nix-darwin が launchd.user.agents.<name> に付けるラベル。
  # 明示しておくと plist の名前が読めるので、入れ替えのときに登録を戻せる。
  label = "org.nixos.comet";

  homeDirectory = "/Users/${cfg.user}";

  # root から利用者へ降りて実行する。ログイン中のセッションを引き継げるよう
  # `sudo -u` を使う（`su` ではキーチェーンに届かないことがある）。
  #
  # **`env` を挟むこと。** `sudo -u x FOO=1 cmd` の形は sudoers の `setenv` が
  # 無いと「その環境変数は設定できない」で弾かれる。`env` に渡せばただの引数になる。
  asUser = command: ''
    /usr/bin/sudo -u ${lib.escapeShellArg cfg.user} /usr/bin/env ${command}
  '';
in
{
  options.services.comet = (import ./module-options.nix {
    inherit lib pkgs defaultPackage homeDirectory;
  }) // {
    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser or "";
      defaultText = lib.literalExpression "config.system.primaryUser";
      description = ''
        comet を動かす利用者。設定ファイルと launchd agent はこの利用者のホームに置く。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "services.comet は macOS でのみ使える。";
      }
      {
        assertion = cfg.user != "";
        message = "services.comet.user を設定する（または system.primaryUser を設定する）。";
      }
    ];

    # `comet --send` / `--query` を PATH から使えるようにする（i3-msg 相当）。
    # `.cli` を使うのは `Applications/` を含めないため（passthru.cli の注記を見ること）。
    environment.systemPackages =
      lib.optional (cfg.package != null) (cfg.package.cli or cfg.package);

    launchd.user.agents.comet = lib.mkIf cfg.startService {
      serviceConfig = {
        Label = label;
        ProgramArguments = [ "${cfg.app}/Contents/MacOS/comet" ];
        RunAtLoad = true;
        # 理由不明で落ちたときに上げ直す。
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardOutPath = cfg.logFile;
        StandardErrorPath = cfg.logFile;
      };
    };

    system.activationScripts.postActivation.text = lib.mkAfter (
      # 設定ファイル。書いていないときは置かない。空の TOML を置くと
      # キーバインドが1つも登録されない状態になる。
      (lib.optionalString hasSettings ''
        ${asUser "/bin/mkdir -p ${lib.escapeShellArg "${homeDirectory}/.config/comet"}"}
        ${asUser "/bin/ln -sfn ${configFile} ${lib.escapeShellArg "${homeDirectory}/.config/comet/config.toml"}"}
      '')
      +
      # 本体。ストアから `app` へ入れ替える。
      (if cfg.package != null then ''
        ${asUser (lib.concatStringsSep " " [
          "COMET_SOURCE_APP=${lib.escapeShellArg "${cfg.package}/Applications/comet.app"}"
          "COMET_DESTINATION=${lib.escapeShellArg cfg.app}"
          "COMET_SIGNING_IDENTITY=${lib.escapeShellArg (toString cfg.signingIdentity)}"
          "COMET_LAUNCHD_LABEL=${lib.escapeShellArg (lib.optionalString cfg.startService label)}"
          "COMET_STATE_DIR=${lib.escapeShellArg "${homeDirectory}/Library/Application Support/comet"}"
          "${pkgs.bash}/bin/bash ${./install-app.sh}"
        ])}
      '' else ''
        if [ ! -x ${lib.escapeShellArg "${cfg.app}/Contents/MacOS/comet"} ]; then
          echo "comet: comet.app が ${cfg.app} に無い。services.comet.package を設定する" >&2
        fi
      '')
    );
  };
}
