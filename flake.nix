{
  description = "comet — macOS 向けのタイリングウィンドウマネージャ";

  # **ビルドは提供しない。** comet は Swift 6 を要求するが nixpkgs の Swift は 5.10 で、
  # ストアの中では組めない。加えてアクセシビリティ権限はアプリの同一性に紐づくため、
  # 更新のたびにパスが変わるストアへ本体を置くと権限が毎回外れる。
  #
  # そのためこの flake が受け持つのは**設定・自動起動**で、本体は
  # `./scripts/install-app.sh` が `~/Applications/comet.app` へ入れる。

  outputs = { self }: {
    homeManagerModules = rec {
      comet = ./nix/home-manager.nix;
      default = comet;
    };
  };
}
