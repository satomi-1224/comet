// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "comet",
    platforms: [.macOS(.v14)],
    targets: [
        // 全体で共有する土台（ログ等）。他のどのターゲットにも依存しない。
        .target(name: "CometSupport"),

        // ホットキーと入力。
        .target(name: "CometInput", dependencies: ["CometSupport"]),

        // Accessibility API へのアクセスを集約する層。
        // ここ以外から AX API を直接呼んではならない。
        .target(name: "CometAccessibility", dependencies: ["CometSupport"]),

        .executableTarget(
            name: "comet",
            dependencies: ["CometSupport", "CometInput", "CometAccessibility"]
        ),

        .testTarget(name: "CometSupportTests", dependencies: ["CometSupport"]),
        .testTarget(name: "CometInputTests", dependencies: ["CometInput"]),
        .testTarget(name: "CometAccessibilityTests", dependencies: ["CometAccessibility"]),
    ]
)
