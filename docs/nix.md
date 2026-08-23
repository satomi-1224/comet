# Nix で管理する

[← README](../README.md)

本体・設定・自動起動をまとめて宣言でき、**更新も switch で完結します**。
一度だけ入れたいだけなら `nix run github:satomi-1224/comet#install` で足ります。

## モジュールを読み込む

本体・設定・自動起動をまとめて宣言できます。**更新も switch で完結します。**

flake を input に足して、使っている仕組みに合わせてモジュールを読み込みます。

<details open>
<summary><b>home-manager</b>（推奨）</summary>

```nix
{
  inputs.comet.url = "github:satomi-1224/comet";

  # home-manager の設定
  imports = [ inputs.comet.homeManagerModules.default ];

  programs.comet = {
    enable = true;
    settings = {
      gaps = { inner-horizontal = 7; inner-vertical = 7; };
      border.color-focused = "#7aa2f7";
      wallpaper.dir = "~/Pictures/wallpapers";
      mode.main.binding = {
        alt-h = "focus left";
        alt-l = "focus right";
        alt-1 = "workspace 1";
      };
    };
  };
}
```

</details>

<details>
<summary><b>nix-darwin</b>（home-manager を使っていない場合）</summary>

```nix
{
  inputs.comet.url = "github:satomi-1224/comet";

  # nix-darwin の設定
  imports = [ inputs.comet.darwinModules.default ];

  # nix-darwin は launchd.user.agents を使う構成にこれを要求します
  system.primaryUser = "あなたのユーザ名";

  services.comet = {
    enable = true;
    settings = { /* 上と同じ */ };
  };
}
```

`services.comet` の選択肢は `programs.comet` と同じです（`user` だけ増えます）。
`user` を書くのは、`system.primaryUser` とは**別の利用者**で動かしたいときだけです。

> [!NOTE]
> nix-darwin の activation は root で走り、`sudo -u` で利用者へ降ります。
> 環境によってはキーチェーンに届かず**署名し直しに失敗**して ad-hoc のままになります。
> その場合は端末から一度だけ `nix run github:satomi-1224/comet#install` を実行してください。
> home-manager 側の activation は利用者のセッションで走るのでこの問題はありません。

</details>

| オプション | 既定 | 内容 |
|---|---|---|
| `enable` | `false` | 有効にする |
| `package` | この flake の comet | 導入する本体。`null` にすると本体を Nix の管理外にする |
| `settings` | `{}` | `config.toml` の内容（TOML へ変換して置く） |
| `settingsFile` | `null` | 書いてある `config.toml` をそのまま置く。`settings` より優先 |
| `app` | `~/Applications/comet.app` | 本体を置く場所 |
| `signingIdentity` | `"comet-dev"` | 置いたあと署名し直す ID。`null` で署名し直さない |
| `startService` | `true` | launchd agent として登録し、ログイン時に起動する |
| `logFile` | `~/Library/Logs/comet.log` | launchd から起動したときのログ |

**キーバインドは置き換えです**（既定へ追加されるのではありません）。書くなら必要なものを
全部書いてください。設定は保存を検知して自動で読み直すので、switch すればそのまま反映されます。

> [!NOTE]
> `enable = false` にすると launchd の登録と設定ファイルは消えますが、
> **`app` に置いた本体は残ります**（ストアの外なので Nix が回収しません）。
> 消すなら `rm -rf ~/Applications/comet.app` と
> `rm -rf ~/Library/Application\ Support/comet` を手で実行してください。

## 更新する

```bash
nix flake update comet
home-manager switch          # nix-darwin なら darwin-rebuild switch
```

本体を組み直し、`app` へ入れ替え、launchd を上げ直すところまで switch がやります。
**本体が変わっていなければ何もしません**（常駐中の comet を落としません）。

## なぜストアから直接動かさないのか

アクセシビリティ権限は**コード署名の同一性**に紐づきます。Nix ストアの中では
キーチェーンに触れないため ad-hoc 署名しかできず、内容が変わるたびに cdhash が変わって
権限が外れます。そこでモジュールは、ストアで組んだものを `app`（既定
`~/Applications/comet.app`）へ写し、**固定の署名 ID で署名し直します**。
署名の要件が更新をまたいで同じになるので、権限を付け直さずに済みます。

```
designated => identifier "local.comet" and certificate leaf = H"50e54a3c…"
                                          ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                                          パスにも内容にも依らないので更新しても外れない
```

署名 ID は `nix run github:satomi-1224/comet#make-signing-cert` で作れます。
無い場合は ad-hoc のまま進み（動作はします）、警告を出します。

## ビルドについて

`nix build .#comet` で `comet.app` が組めます。ただし**コンパイラだけはホストの
Command Line Tools / Xcode を借ります**。comet は Swift 6 を要求しますが nixpkgs の
Swift は 5.10 のためです。そのためパッケージは `__noChroot = true` を付けており、
ビルドには次が要ります。

- Swift 6 が入った Command Line Tools か Xcode
- `nix.settings.sandbox` が `false` か `relaxed`（`relaxed` の場合は trusted-users に入っていること）

依存パッケージ（TOMLDecoder）はハッシュ固定でストアから与えるので、
ビルド中にネットワークへは出ません。

> [!TIP]
> `import Foundation` を含むコンパイルが
> `redefinition of module 'SwiftBridging'` で落ちる Mac があります。
> Xcode 15 期の `<toolchain>/usr/include/swift/module.modulemap` が残っているのが原因です。
> `scripts/modulemap-workaround.sh` が VFS overlay で自動的に回避するので、
> Nix ビルドでも `./scripts/build-app.sh` / `./scripts/test.sh` でも意識は要りません
> （二重定義を見つけたときだけ効きます）。
> 恒久的に直すなら `sudo mv <toolchain>/usr/include/swift/module.modulemap{,.disabled}`。

## flake の出力

| 出力 | 内容 |
|---|---|
| `packages.<system>.comet` | `comet.app`（`bin/comet` も置くので `--send` / `--query` が使える） |
| `packages.<system>.comet-debug` | debug ビルド |
| `apps.<system>.default` | ストアから前景で起動する（ログが端末に出る。常用には向かない） |
| `apps.<system>.install` | 組んで `~/Applications/comet.app` へ入れて起動する |
| `apps.<system>.make-signing-cert` | 固定の署名 ID を作る |
| `homeManagerModules.default` | home-manager モジュール（`programs.comet`） |
| `darwinModules.default` | nix-darwin モジュール（`services.comet`） |
| `overlays.default` | `pkgs.comet` を足す |
