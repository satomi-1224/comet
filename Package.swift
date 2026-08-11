// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "comet",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Swift 標準に TOML パーサは無い。Codable 対応の純 Swift 実装を使う（設計書 §10.2）。
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5")
    ],
    targets: [
        // 全体で共有する土台（ログ等）。他のどのターゲットにも依存しない。
        .target(name: "CometSupport"),

        // ホットキーと入力。
        .target(name: "CometInput", dependencies: ["CometSupport"]),

        // Accessibility API へのアクセスを集約する層。
        // ここ以外から AX API を直接呼んではならない。
        .target(name: "CometAccessibility", dependencies: ["CometSupport"]),

        // 状態機械とレイアウト。副作用のない計算はここに集める。
        .target(name: "CometCore", dependencies: ["CometSupport", "CometAccessibility"]),

        // 内蔵UI。枠線・インジケータ・壁紙。CometCore は AppKit の表示を知らない。
        .target(name: "CometDecoration", dependencies: ["CometSupport", "CometCore"]),

        // 設定ファイルの読み込み。CometCore の型（Gaps 等）へは依存させ、
        // 逆向き（Core → Config）には依存させない。
        .target(
            name: "CometConfig",
            dependencies: [
                "CometSupport", "CometCore", "CometInput",
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ]
        ),

        // 画面の実測。「目視でしか判定できない」と諦めていた項目を機械で判定するための土台。
        // 撮った画像の画素と、ウィンドウの実座標を読む純粋な計算だけを置く。
        // 製品コードからは参照しない（アプリバンドルにも入れない）。
        .target(name: "CometProbe"),

        .executableTarget(
            name: "comet",
            dependencies: [
                "CometSupport", "CometInput", "CometAccessibility", "CometCore", "CometConfig",
                "CometDecoration",
            ]
        ),

        // 検証専用の道具。`scripts/verify.sh` から呼ぶ。
        //
        // 画面の撮影そのものは `screencapture` に任せる。**画面収録の権限を
        // comet 側に要求しないため**で、端末が既に持っている権限で撮った PNG を
        // ここが読むだけにしてある。
        //
        // 名前を `cometprobe` にできないのは、macOS のファイルシステムが
        // 大文字小文字を区別せず `Sources/CometProbe` と同じ場所になるため。
        .executableTarget(name: "comet-probe", dependencies: ["CometProbe"]),

        .testTarget(name: "CometSupportTests", dependencies: ["CometSupport"]),
        .testTarget(name: "CometInputTests", dependencies: ["CometInput"]),
        .testTarget(name: "CometAccessibilityTests", dependencies: ["CometAccessibility"]),
        .testTarget(name: "CometCoreTests", dependencies: ["CometCore"]),
        .testTarget(name: "CometConfigTests", dependencies: ["CometConfig"]),
        .testTarget(name: "CometDecorationTests", dependencies: ["CometDecoration"]),
        .testTarget(name: "CometProbeTests", dependencies: ["CometProbe"]),
    ]
)
