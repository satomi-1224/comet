{
  description = "comet — macOS 向けのタイリングウィンドウマネージャ";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    in
    {
      packages = eachSystem (pkgs: rec {
        comet = pkgs.callPackage ./nix/package.nix { src = self; };
        comet-debug = comet.override { configuration = "debug"; };
        default = comet;
      });

      apps = eachSystem (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          comet = self.packages.${system}.comet;

          # 常用の場所へ入れて起動し直す。モジュールを使わずに済ませたいとき、
          # あるいはモジュールを入れる前に一度動かしてみたいとき用。
          #
          #     nix run github:satomi-1224/comet#install
          install = pkgs.writeShellApplication {
            name = "comet-install";
            text = ''
              COMET_SOURCE_APP=${comet}/Applications/comet.app \
              COMET_DESTINATION="''${COMET_DESTINATION:-$HOME/Applications/comet.app}" \
              COMET_SIGNING_IDENTITY="''${COMET_SIGNING_IDENTITY:-comet-dev}" \
              COMET_STANDALONE=1 \
              exec bash ${./nix/install-app.sh}
            '';
          };
          # 固定のコード署名 ID を作る。一度だけ実行すればよい。
          # リポジトリを clone せずに済ませるためにここからも呼べるようにしてある。
          makeSigningCert = pkgs.writeShellApplication {
            name = "comet-make-signing-cert";
            text = "exec bash ${./scripts/make-signing-cert.sh}";
          };
        in
        {
          # ストアから前景で起動する。ログが端末に出る。終了は Ctrl-C。
          # **常用には向かない。** ストアの中は ad-hoc 署名なので、組み直すたびに
          # アクセシビリティ権限を付け直すことになる。常用は #install のほう。
          default = {
            type = "app";
            program = "${comet}/bin/comet";
          };
          comet = self.apps.${system}.default;
          install = {
            type = "app";
            program = "${install}/bin/comet-install";
          };
          make-signing-cert = {
            type = "app";
            program = "${makeSigningCert}/bin/comet-make-signing-cert";
          };
        }
      );

      devShells = eachSystem (pkgs: {
        # Swift 6 が要るので、コンパイラはホストの Command Line Tools / Xcode を使う。
        # ここで用意するのは周辺の道具だけ。
        default = pkgs.mkShellNoCC {
          packages = [ pkgs.nixfmt-rfc-style ];
          shellHook = ''
            echo "comet — ビルド: ./scripts/build-app.sh / テスト: ./scripts/test.sh"
            echo "        Nix で組む: nix build .#comet"
          '';
        };
      });

      # `nix flake check` で本体が組めることを確かめる。
      # **テストはここでは走らせない。** swift-testing の実行にホストの
      # Testing.framework が要り、一部のテストはウィンドウサーバに繋がる必要がある。
      # テストは `./scripts/test.sh` で走らせること。
      checks = eachSystem (pkgs: { comet = self.packages.${pkgs.stdenv.hostPlatform.system}.comet; });

      overlays.default = final: _prev: {
        comet = final.callPackage ./nix/package.nix { src = self; };
      };

      homeManagerModules = rec {
        comet = import ./nix/home-manager.nix { cometPackages = self.packages; };
        default = comet;
      };

      darwinModules = rec {
        comet = import ./nix/darwin.nix { cometPackages = self.packages; };
        default = comet;
      };
    };
}
