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

        // 設定ファイルの読み込み。CometCore の型（Gaps 等）へは依存させ、
        // 逆向き（Core → Config）には依存させない。
        .target(
            name: "CometConfig",
            dependencies: [
                "CometSupport", "CometCore", "CometInput",
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ]
        ),

        .executableTarget(
            name: "comet",
            dependencies: [
                "CometSupport", "CometInput", "CometAccessibility", "CometCore", "CometConfig",
            ]
        ),

        .testTarget(name: "CometSupportTests", dependencies: ["CometSupport"]),
        .testTarget(name: "CometInputTests", dependencies: ["CometInput"]),
        .testTarget(name: "CometAccessibilityTests", dependencies: ["CometAccessibility"]),
        .testTarget(name: "CometCoreTests", dependencies: ["CometCore"]),
        .testTarget(name: "CometConfigTests", dependencies: ["CometConfig"]),
    ]
)
