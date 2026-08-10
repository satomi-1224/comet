import CoreGraphics
import Testing
import CometCore
import CometInput
import CometSupport

@testable import CometConfig

/// 設定ファイルの読み込み。
///
/// **設定の誤りで起動を止めない**のが方針。読めなかった項目は既定値に落として
/// `problems` に理由を積み、利用者が原因を突き止められるようにする。
/// ホットキーが1つ効かないだけで WM が上がらないのは困る。
@Suite("ConfigLoader")
struct ConfigLoaderTests {

    // MARK: - 組み込みの既定

    @Test("既定の設定は自分自身のパーサで読める")
    func builtInConfigurationParses() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        #expect(!configuration.bindings.isEmpty)
    }

    @Test("既定の設定に構文の問題は無い")
    func builtInConfigurationHasNoSyntaxProblems() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        let unexpected = configuration.problems.filter { $0.kind != .unsupportedCommand }
        #expect(unexpected.isEmpty, "\(unexpected.map(\.description))")
    }

    @Test("既定の設定は移植表どおりのバインドを持つ")
    func builtInBindingsMatchThePortingTable() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        let commands = Dictionary(
            uniqueKeysWithValues: configuration.bindings.map { ($0.spec, $0.commands) })

        #expect(commands["alt-h"] == [.focus(.left)])
        #expect(commands["alt-j"] == [.focus(.down)])
        #expect(commands["alt-k"] == [.focus(.up)])
        #expect(commands["alt-l"] == [.focus(.right)])
        #expect(commands["alt-shift-h"] == [.move(.left)])
        #expect(commands["alt-ctrl-l"] == [.resize(.width, delta: 50)])
        #expect(commands["alt-ctrl-h"] == [.resize(.width, delta: -50)])
        #expect(commands["alt-e"] == [.joinWith(.right)])
        #expect(commands["alt-w"] == [.joinWith(.down)])
        #expect(commands["alt-slash"] == [.layout([.tiles, .horizontal, .vertical])])
        #expect(commands["alt-shift-f"] == [.layout([.floating, .tiling])])
    }

    // 後続 Phase のコマンドは既定に書いてあるが、まだ実行できない。落としたことを黙らない。
    @Test("未対応のコマンドは問題として記録される")
    func unsupportedCommandsAreReported() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        let unsupported = configuration.problems.filter { $0.kind == .unsupportedCommand }

        #expect(!unsupported.isEmpty, "fullscreen などが含まれるはず")
        #expect(unsupported.contains { $0.detail.contains("fullscreen") })
        #expect(!configuration.bindings.contains { $0.spec == "alt-semicolon" }, "登録はされない")
    }

    @Test("既定の設定はワークスペースのバインドを持つ")
    func builtInBindingsIncludeWorkspaces() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        let commands = Dictionary(
            uniqueKeysWithValues: configuration.bindings.map { ($0.spec, $0.commands) })

        #expect(commands["alt-1"] == [.workspace(.index(1))])
        #expect(commands["alt-0"] == [.workspace(.index(10))])
        #expect(commands["alt-tab"] == [.workspace(.backAndForth)])
        #expect(
            commands["alt-shift-3"] == [.moveNodeToWorkspace(3), .workspace(.index(3))],
            "移動して追従する2連コマンド")
    }

    // MARK: - 各セクション

    @Test("gaps を読める")
    func parsesGaps() throws {
        let configuration = try ConfigLoader.parse(
            """
            [gaps]
            inner-horizontal = 8
            inner-vertical   = 4
            outer-top        = 1
            outer-bottom     = 2
            outer-left       = 3
            outer-right      = 4
            """)

        #expect(configuration.gaps.innerHorizontal == 8)
        #expect(configuration.gaps.innerVertical == 4)
        #expect(configuration.gaps.outerTop == 1)
        #expect(configuration.gaps.outerBottom == 2)
        #expect(configuration.gaps.outerLeft == 3)
        #expect(configuration.gaps.outerRight == 4)
    }

    @Test("gaps は小数も受ける")
    func parsesFractionalGaps() throws {
        let configuration = try ConfigLoader.parse("[gaps]\ninner-horizontal = 7.5")
        #expect(configuration.gaps.innerHorizontal == 7.5)
    }

    @Test("書かれていない項目は既定のまま")
    func missingKeysKeepDefaults() throws {
        let configuration = try ConfigLoader.parse("[gaps]\ninner-horizontal = 8")
        let fallback = Configuration()
        #expect(configuration.gaps.outerTop == fallback.gaps.outerTop)
        #expect(configuration.normalization == fallback.normalization)
    }

    @Test("normalization を読める")
    func parsesNormalization() throws {
        let configuration = try ConfigLoader.parse(
            """
            [normalization]
            flatten-containers          = false
            opposite-orientation-nested = false
            """)

        #expect(configuration.normalization.flattenContainers == false)
        #expect(configuration.normalization.oppositeOrientationForNested == false)
    }

    @Test("layout の挿入方法と既定の向きを読める")
    func parsesLayoutSection() throws {
        let configuration = try ConfigLoader.parse(
            """
            [layout]
            default-orientation = "vertical"
            insertion           = "sibling"
            """)

        #expect(configuration.defaultOrientation == .vertical)
        #expect(configuration.insertionStrategy == .sibling)
    }

    @Test("既定の挿入方法は dwindle")
    func defaultInsertionIsDwindle() {
        #expect(Configuration().insertionStrategy == .split)
        #expect(Configuration().defaultOrientation == .auto)
    }

    @Test("知らない値は既定に落として問題として記録する")
    func invalidEnumValueIsReported() throws {
        let configuration = try ConfigLoader.parse("[layout]\ninsertion = \"spiral\"")

        #expect(configuration.insertionStrategy == .split, "既定に落ちる")
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("log-level を読める")
    func parsesLogLevel() throws {
        #expect(try ConfigLoader.parse("[debug]\nlog-level = \"debug\"").logLevel == .debug)
        #expect(try ConfigLoader.parse("").logLevel == nil, "書かれていなければ指定なし")
    }

    @Test("performance を読める")
    func parsesPerformance() throws {
        let configuration = try ConfigLoader.parse(
            """
            [performance]
            ax-timeout-ms          = 250
            apply-interval-ms      = 16
            max-correction-retries = 5
            """)

        #expect(configuration.performance.axTimeout == 0.25)
        #expect(configuration.performance.applyInterval == 0.016)
        #expect(configuration.performance.maxCorrections == 5)
    }

    @Test("workspaces の個数を読める")
    func parsesWorkspaceCount() throws {
        #expect(try ConfigLoader.parse("[workspaces]\ncount = 4").workspaceCount == 4)
        #expect(Configuration().workspaceCount == 10, "既定は 10")
    }

    @Test("ワークスペースの個数は 1 未満にならない")
    func workspaceCountIsClamped() throws {
        let configuration = try ConfigLoader.parse("[workspaces]\ncount = 0")
        #expect(configuration.workspaceCount == 1)
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("非表示の方式を読める")
    func parsesHiddenStrategy() throws {
        #expect(
            try ConfigLoader.parse("[workspaces]\nhidden = \"off-screen\"")
                .hiddenWindowStrategy == .offScreen)
        #expect(Configuration().hiddenWindowStrategy == .hideApp, "既定はアプリごと非表示")
        #expect(
            try ConfigLoader.parse(Configuration.defaultTOML).hiddenWindowStrategy == .hideApp)
    }

    @Test("非表示の方式が不明なら既定に落とす")
    func invalidHiddenStrategyIsReported() throws {
        let configuration = try ConfigLoader.parse("[workspaces]\nhidden = \"minimize\"")
        #expect(configuration.hiddenWindowStrategy == .hideApp)
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("Phase 4 のつまみを読める")
    func parsesPhase4Options() throws {
        let configuration = try ConfigLoader.parse(
            """
            [workspaces]
            focus-follows-activation = false

            [performance]
            disable-enhanced-ui = false

            [debug]
            timing = true
            """)

        #expect(configuration.focusFollowsActivation == false)
        #expect(configuration.performance.disablesEnhancedUserInterface == false)
        #expect(configuration.performance.isTimingEnabled)
    }

    // セクションの有無で他のセクションの読み取りが変わってはいけない。
    @Test("timing は performance が無くても読める")
    func timingIsIndependentOfPerformanceSection() throws {
        let configuration = try ConfigLoader.parse("[debug]\ntiming = true")
        #expect(configuration.performance.isTimingEnabled)
        #expect(configuration.performance.axTimeout == 0.1, "他の値は既定のまま")
    }

    @Test("performance だけ書いても timing の既定は保たれる")
    func performanceAloneKeepsTimingDefault() throws {
        let configuration = try ConfigLoader.parse("[performance]\nax-timeout-ms = 200")
        #expect(configuration.performance.axTimeout == 0.2)
        #expect(!configuration.performance.isTimingEnabled)
    }

    // 設定ファイルは既定を置き換える。`[gaps]` だけ書いてキーが全部死ぬのは
    // 分かりにくいので必ず知らせる。
    @Test("バインドが1つも無ければ問題として記録する")
    func emptyBindingsAreReported() throws {
        let configuration = try ConfigLoader.parse("[gaps]\ninner-horizontal = 3")
        #expect(configuration.bindings.isEmpty)
        #expect(configuration.problems.contains { $0.kind == .noBindings })
    }

    @Test("既定の設定にはバインドの警告が出ない")
    func builtInHasBindings() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        #expect(!configuration.problems.contains { $0.kind == .noBindings })
    }

    @Test("Phase 4 のつまみの既定値")
    func phase4Defaults() {
        let fallback = Configuration()
        #expect(fallback.focusFollowsActivation, "既定で追従する")
        #expect(fallback.performance.disablesEnhancedUserInterface, "既定で無効化する")
        #expect(!fallback.performance.isTimingEnabled, "計測は既定で切る")
    }

    @Test("既定の設定は Phase 4 のつまみを明示している")
    func builtInConfigurationDocumentsPhase4Options() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        #expect(configuration.focusFollowsActivation)
        #expect(configuration.performance.disablesEnhancedUserInterface)
        #expect(!configuration.performance.isTimingEnabled)
    }

    // 負のギャップは配置を破壊する（境界が領域の外に出てウィンドウが重なる）。
    // 設定の打ち間違いで壊れた配置にならないよう、下限で止める。
    @Test("負のギャップは 0 に丸めて問題として記録する")
    func negativeGapsAreClamped() throws {
        let configuration = try ConfigLoader.parse(
            """
            [gaps]
            inner-horizontal = -50
            outer-top        = -1
            """)

        #expect(configuration.gaps.innerHorizontal == 0)
        #expect(configuration.gaps.outerTop == 0)
        #expect(configuration.problems.filter { $0.kind == .invalidValue }.count == 2)
    }

    // 0 にすると `asyncAfter` が待たずに回り続けて CPU を焼く。
    @Test("適用間隔は下限で止める")
    func applyIntervalIsClamped() throws {
        let configuration = try ConfigLoader.parse("[performance]\napply-interval-ms = 0")
        #expect(configuration.performance.applyInterval >= 0.001)
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("AX タイムアウトは下限と上限で止める")
    func axTimeoutIsClamped() throws {
        #expect(
            try ConfigLoader.parse("[performance]\nax-timeout-ms = 0").performance.axTimeout >= 0.01)
        #expect(
            try ConfigLoader.parse("[performance]\nax-timeout-ms = 60000").performance.axTimeout
                <= 5)
    }

    @Test("補正回数は負にならない")
    func maxCorrectionsIsClamped() throws {
        let configuration = try ConfigLoader.parse("[performance]\nmax-correction-retries = -3")
        #expect(configuration.performance.maxCorrections == 0)
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("知らないセクションやキーは黙って無視する")
    func unknownKeysAreIgnored() throws {
        let configuration = try ConfigLoader.parse(
            """
            start-at-login = true

            [indicator]
            style = "both"

            [gaps]
            inner-horizontal = 3
            futureproof      = "yes"
            """)

        #expect(configuration.gaps.innerHorizontal == 3)
    }

    @Test("start-at-login を読める")
    func parsesStartAtLogin() throws {
        #expect(try ConfigLoader.parse("start-at-login = true").startAtLogin)
        #expect(!Configuration().startAtLogin, "既定では登録しない")
        #expect(!(try ConfigLoader.parse(Configuration.defaultTOML).startAtLogin))
    }

    // MARK: - 見た目

    @Test("border を読める")
    func parsesBorder() throws {
        let configuration = try ConfigLoader.parse(
            """
            [border]
            enabled         = false
            width           = 3.5
            radius          = 6
            color-focused   = "#ff0000"
            """)

        #expect(configuration.border.isEnabled == false)
        #expect(configuration.border.width == 3.5)
        #expect(configuration.border.radius == 6)
        #expect(configuration.border.focusedColor == RGBAColor(hex: "#ff0000"))
    }

    // 書いてあるのに効かない項目は黙って無視しない。
    @Test("未対応の設定項目は問題として記録する")
    func unsupportedOptionIsReported() throws {
        let configuration = try ConfigLoader.parse("[border]\ncolor-unfocused = \"#ffffff\"")
        #expect(configuration.problems.contains { $0.kind == .unsupportedOption })
    }

    @Test("色を解釈できなければ既定に落として問題として記録する")
    func invalidColorIsReported() throws {
        let configuration = try ConfigLoader.parse("[border]\ncolor-focused = \"blue\"")

        #expect(configuration.border.focusedColor == Configuration().border.focusedColor)
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("枠線の太さと半径は範囲で止める")
    func borderMetricsAreClamped() throws {
        let configuration = try ConfigLoader.parse("[border]\nwidth = -1\nradius = 9999")
        #expect(configuration.border.width == 0)
        #expect(configuration.border.radius == 100)
    }

    @Test("indicator を読める")
    func parsesIndicator() throws {
        let configuration = try ConfigLoader.parse(
            """
            [indicator]
            style           = "menubar"
            hud-duration-ms = 800
            """)

        #expect(configuration.indicator == .menubar)
        #expect(configuration.hudDuration == 0.8)
    }

    @Test("indicator の値が不明なら既定に落とす")
    func invalidIndicatorStyleIsReported() throws {
        let configuration = try ConfigLoader.parse("[indicator]\nstyle = \"neon\"")
        #expect(configuration.indicator == .both)
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("wallpaper のマップを読める")
    func parsesWallpaperMap() throws {
        let configuration = try ConfigLoader.parse(
            """
            [wallpaper]
            enabled = true

            [wallpaper.map]
            1 = "~/a.jpg"
            3 = "/b.png"
            """)

        #expect(configuration.wallpapers == [1: "~/a.jpg", 3: "/b.png"])
    }

    @Test("wallpaper を無効にするとマップを読まない")
    func disabledWallpaperIsIgnored() throws {
        let configuration = try ConfigLoader.parse(
            """
            [wallpaper]
            enabled = false

            [wallpaper.map]
            1 = "~/a.jpg"
            """)

        #expect(configuration.wallpapers.isEmpty)
    }

    @Test("wallpaper のキーがワークスペース番号でなければ問題として記録する")
    func invalidWallpaperKeyIsReported() throws {
        let configuration = try ConfigLoader.parse(
            """
            [wallpaper.map]
            main = "~/a.jpg"
            0    = "~/b.jpg"
            """)

        #expect(configuration.wallpapers.isEmpty)
        #expect(configuration.problems.filter { $0.kind == .invalidValue }.count == 2)
    }

    @Test("既定の設定は見た目の項目を明示している")
    func builtInDocumentsAppearance() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        #expect(configuration.border.isEnabled)
        #expect(configuration.border.focusedColor == RGBAColor(hex: "#7aa2f7"))
        #expect(configuration.indicator == .both)
        #expect(configuration.hudDuration == 0.4)
        #expect(configuration.wallpapers.isEmpty, "既定では壁紙を指定しない")
    }

    // MARK: - バインド

    @Test("1つのコマンドでも配列でも読める")
    func parsesSingleAndMultipleCommands() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-h = "focus left"
            alt-g = ["focus left", "move right"]
            """)

        let commands = Dictionary(
            uniqueKeysWithValues: configuration.bindings.map { ($0.spec, $0.commands) })
        #expect(commands["alt-h"] == [.focus(.left)])
        #expect(commands["alt-g"] == [.focus(.left), .move(.right)])
    }

    @Test("バインドの並びは決定的")
    func bindingOrderIsDeterministic() throws {
        let toml = """
            [mode.main.binding]
            alt-l = "focus right"
            alt-h = "focus left"
            alt-j = "focus down"
            """
        let first = try ConfigLoader.parse(toml).bindings.map(\.spec)
        let second = try ConfigLoader.parse(toml).bindings.map(\.spec)

        #expect(first == second)
        #expect(first == ["alt-h", "alt-j", "alt-l"], "キー順に並ぶ")
    }

    @Test("解釈できないキー指定はそのバインドだけを落とす")
    func invalidKeySpecDropsOnlyThatBinding() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-h    = "focus left"
            hyper-zz = "focus right"
            """)

        #expect(configuration.bindings.map(\.spec) == ["alt-h"])
        #expect(configuration.problems.contains { $0.kind == .invalidBinding })
    }

    @Test("解釈できないコマンドはそのバインドだけを落とす")
    func invalidCommandDropsOnlyThatBinding() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-h = "focus left"
            alt-l = "frobnicate"
            """)

        #expect(configuration.bindings.map(\.spec) == ["alt-h"])
        #expect(configuration.problems.contains { $0.kind == .invalidCommand })
    }

    @Test("配列の一部が解釈できなければバインド全体を落とす")
    func partiallyInvalidCommandListDropsTheBinding() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-g = ["focus left", "frobnicate"]
            """)

        #expect(configuration.bindings.isEmpty, "半分だけ実行されるほうが混乱する")
        #expect(configuration.problems.contains { $0.kind == .invalidCommand })
    }

    @Test("main 以外のモードはまだ読まない")
    func onlyTheMainModeIsRead() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-h = "focus left"

            [mode.resize.binding]
            h = "resize width -50"
            """)

        #expect(configuration.bindings.map(\.spec) == ["alt-h"])
        #expect(configuration.problems.contains { $0.kind == .unsupportedMode })
    }

    // MARK: - ウィンドウルール

    @Test("window-rule を読める")
    func parsesWindowRules() throws {
        let configuration = try ConfigLoader.parse(
            """
            [[window-rule]]
            if-app-id = "com.apple.systempreferences"
            run       = "layout floating"

            [[window-rule]]
            if-window-title-substring = "Picture in Picture"
            run                       = "layout floating"
            """)

        #expect(configuration.windowRules.count == 2)
        #expect(configuration.windowRules[0].appID == "com.apple.systempreferences")
        #expect(configuration.windowRules[0].action == .float)
        #expect(configuration.windowRules[1].titleSubstring == "Picture in Picture")
    }

    @Test("条件が無いルールは全てに当たるので拒否する")
    func ruleWithoutConditionIsRejected() throws {
        let configuration = try ConfigLoader.parse(
            """
            [[window-rule]]
            run = "layout floating"
            """)

        #expect(configuration.windowRules.isEmpty, "全ウィンドウがフローティングになってしまう")
        #expect(configuration.problems.contains { $0.kind == .invalidRule })
    }

    @Test("未対応の run は問題として記録する")
    func unknownRuleActionIsReported() throws {
        let configuration = try ConfigLoader.parse(
            """
            [[window-rule]]
            if-app-id = "com.example.app"
            run       = "move-node-to-workspace 3"
            """)

        #expect(configuration.windowRules.isEmpty)
        #expect(configuration.problems.contains { $0.kind == .invalidRule })
    }

    @Test("ルールの一致はバンドル ID とタイトルで判定する")
    func ruleMatching() {
        let byApp = WindowRule(appID: "com.example.app", titleSubstring: nil, action: .float)
        #expect(byApp.matches(bundleID: "com.example.app", title: nil))
        #expect(!byApp.matches(bundleID: "com.example.other", title: nil))
        #expect(!byApp.matches(bundleID: nil, title: nil))

        let byTitle = WindowRule(appID: nil, titleSubstring: "設定", action: .float)
        #expect(byTitle.matches(bundleID: nil, title: "システム設定"))
        #expect(!byTitle.matches(bundleID: nil, title: "Safari"))
        #expect(!byTitle.matches(bundleID: nil, title: nil))

        // 両方書いてあれば両方満たす必要がある。
        let both = WindowRule(appID: "com.example.app", titleSubstring: "設定", action: .float)
        #expect(both.matches(bundleID: "com.example.app", title: "設定"))
        #expect(!both.matches(bundleID: "com.example.app", title: "その他"))
    }

    // MARK: - ファイル

    @Test("TOML として壊れていれば読み込みを失敗させる")
    func brokenTOMLThrows() {
        #expect(throws: (any Error).self) {
            try ConfigLoader.parse("[gaps\ninner-horizontal = ")
        }
    }

    @Test("ファイルが無ければ組み込みの既定になる")
    func missingFileFallsBackToBuiltIn() {
        let result = ConfigLoader.load(path: "/nonexistent/comet/config.toml")
        #expect(result.source == .builtIn)
        #expect(!result.configuration.bindings.isEmpty)
    }

    @Test("既定のパスは XDG の場所")
    func defaultPathIsUnderConfigHome() {
        #expect(ConfigLoader.defaultPath().hasSuffix("/comet/config.toml"))
    }
}
