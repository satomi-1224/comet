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

    /// **既定設定に効かないバインドを置かない。** 置くと、起動のたびに
    /// 「未対応」の行が出て、本当の設定間違いが埋もれる。
    @Test("既定設定に未対応のコマンドは無い")
    func theDefaultConfigurationHasNoUnsupportedCommands() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        let problems = configuration.problems.filter {
            $0.kind == .unsupportedCommand || $0.kind == .invalidCommand
        }
        #expect(problems.isEmpty, "\(problems.map(\.detail))")
    }

    // 未対応のコマンドを書いたら、落としたことを黙らない。
    @Test("未対応のコマンドは問題として記録される")
    func unsupportedCommandsAreReported() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-s = "macos-native-fullscreen"
            alt-semicolon = "fullscreen"
            """)
        let unsupported = configuration.problems.filter { $0.kind == .unsupportedCommand }

        #expect(unsupported.contains { $0.detail.contains("macos-native-fullscreen") })
        #expect(!configuration.bindings.contains { $0.spec == "alt-s" }, "登録はされない")
        // 実装済みのものは登録される。
        #expect(configuration.bindings.contains { $0.spec == "alt-semicolon" }, "fullscreen は実装済み")
    }

    /// i3 の綴りをそのまま書き写しても通ること。**指が覚えているほうで通らないと
    /// 設定を持ってきた時点で無反応になる。**
    @Test("既定設定は i3 の語彙を含む")
    func theDefaultConfigurationCoversTheI3Vocabulary() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        let commands = Dictionary(
            uniqueKeysWithValues: configuration.bindings.map { ($0.spec, $0.commands) })

        #expect(commands["alt-enter"] == [.exec("open -a Terminal")])
        #expect(commands["alt-b"] == [.split(.horizontal)])
        #expect(commands["alt-v"] == [.split(.vertical)])
        #expect(commands["alt-a"] == [.focusContainer(.parent)])
        #expect(commands["alt-shift-a"] == [.focusContainer(.child)])
        #expect(commands["alt-space"] == [.focusLayer(.toggle)])
        #expect(commands["alt-period"] == [.workspace(.next)])
        #expect(commands["alt-comma"] == [.workspace(.previous)])
        #expect(commands["alt-shift-slash"] == [.flattenWorkspaceTree])
        #expect(commands["alt-shift-q"] == [.closeWindow])
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
            commands["alt-shift-3"] == [.moveNodeToWorkspace(.index(3)), .workspace(.index(3))],
            "移動して追従する2連コマンド")
    }

    // MARK: - 各セクション

    /// **枠線はウィンドウの外側へ幅ぶん広がる。** アプリ間のギャップが枠線の幅より
    /// 狭いと、枠線が隣のウィンドウの中身に重なる。既定同士がぶつからないよう固定する。
    @Test("既定の枠線は既定のアプリ間ギャップに収まる")
    func defaultBorderFitsInDefaultGap() {
        let configuration = Configuration()
        #expect(configuration.border.width <= configuration.gaps.innerHorizontal)
        #expect(configuration.border.width <= configuration.gaps.innerVertical)
    }

    @Test("既定の間隔はアプリ間も画面の縁も 3pt")
    func defaultGapsAreUniform() {
        // 実際の好みに合わせた既定。細くするときは枠線の幅（2pt）が下限。
        let gaps = Configuration().gaps
        #expect(gaps.innerHorizontal == 3)
        #expect(gaps.innerVertical == 3)
        #expect(gaps.outerTop == 3)
        #expect(gaps.outerBottom == 3)
        #expect(gaps.outerLeft == 3)
        #expect(gaps.outerRight == 3)
    }

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

    /// Hammerspoon から移した巡回の挙動は、時間も範囲も設定で変えられるようにする。
    @Test("focus の巡回設定を読める")
    func parsesFocusCycle() throws {
        let configuration = try ConfigLoader.parse(
            """
            [focus]
            cycle-reset-ms = 800
            cycle-scope    = "all"
            """)

        #expect(configuration.focusCycleReset == 0.8)
        #expect(configuration.focusCycleScope == .allWorkspaces)
    }

    @Test("focus の既定は 1.5 秒・表示中のワークスペースだけ")
    func focusCycleDefaults() {
        #expect(Configuration().focusCycleReset == 1.5)
        #expect(Configuration().focusCycleScope == .activeWorkspace)
    }

    /// 0 は「毎回組み直す」という意味なので、下限で切り上げてはいけない。
    @Test("巡回のリセット時間は 0 を受ける")
    func focusCycleResetAcceptsZero() throws {
        #expect(try ConfigLoader.parse("[focus]\ncycle-reset-ms = 0").focusCycleReset == 0)
    }

    @Test("巡回の範囲が知らない値なら既定に落として記録する")
    func invalidFocusCycleScope() throws {
        let configuration = try ConfigLoader.parse("[focus]\ncycle-scope = \"monitor\"")
        #expect(configuration.focusCycleScope == .activeWorkspace)
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("押しっぱなしの繰り返しの間隔を読める")
    func parsesRepeatTiming() throws {
        let configuration = try ConfigLoader.parse(
            """
            [performance]
            repeat-delay-ms    = 400
            repeat-interval-ms = 50
            """)

        #expect(configuration.performance.repeatDelay == 0.4)
        #expect(configuration.performance.repeatInterval == 0.05)
    }

    @Test("繰り返しの既定は 250ms 後に 30ms 間隔")
    func repeatTimingDefaults() {
        #expect(PerformanceOptions().repeatDelay == 0.25)
        #expect(PerformanceOptions().repeatInterval == 0.03)
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

    @Test("速さと堅牢性のつまみを読める")
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

    @Test("速さと堅牢性のつまみの既定値")
    func phase4Defaults() {
        let fallback = Configuration()
        #expect(fallback.focusFollowsActivation, "既定で追従する")
        #expect(fallback.performance.disablesEnhancedUserInterface, "既定で無効化する")
        #expect(!fallback.performance.isTimingEnabled, "計測は既定で切る")
    }

    @Test("既定の設定は 速さと堅牢性のつまみを明示している")
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

    @Test("フォーカスしていない枠線の色を読める")
    func unfocusedBorderColorIsRead() throws {
        let configuration = try ConfigLoader.parse("[border]\ncolor-unfocused = \"#ffffff\"")
        #expect(configuration.border.unfocusedColor == RGBAColor(hex: "#ffffff"))
        #expect(configuration.border.drawsUnfocused)
        #expect(!configuration.problems.contains { $0.kind == .invalidValue })
    }

    @Test("色を書かなければフォーカス中の1枚だけに枠を描く")
    func unfocusedBorderIsOptional() throws {
        let configuration = try ConfigLoader.parse("[border]\nwidth = 2.0")
        #expect(configuration.border.unfocusedColor == nil)
        #expect(!configuration.border.drawsUnfocused)
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

    /// 1枚ずつ書くのはワークスペースが10個あると現実的でない。
    /// ディレクトリを1つ指定すれば名前順に割り当てられるようにする。
    @Test("wallpaper のディレクトリ指定を読める")
    func parsesWallpaperDirectory() throws {
        let configuration = try ConfigLoader.parse(
            """
            [wallpaper]
            dir = "~/Pictures/wallpapers"
            """)

        #expect(configuration.wallpaperDirectory == "~/Pictures/wallpapers")
    }

    @Test("wallpaper を無効にするとディレクトリも読まない")
    func disabledWallpaperIgnoresDirectory() throws {
        let configuration = try ConfigLoader.parse(
            """
            [wallpaper]
            enabled = false
            dir     = "~/Pictures/wallpapers"
            """)

        #expect(configuration.wallpaperDirectory == nil)
    }

    @Test("ディレクトリを書かなければ未指定のまま")
    func wallpaperDirectoryDefaultsToNil() throws {
        let configuration = try ConfigLoader.parse("[wallpaper]\nenabled = true")
        #expect(configuration.wallpaperDirectory == nil)
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

    @Test("main 以外のモードも読む")
    func otherModesAreRead() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-h = "focus left"

            [mode.resize.binding]
            h = "resize width -50"
            """)

        #expect(configuration.bindings.map(\.spec) == ["alt-h"])
        #expect(configuration.modes["resize"]?.map(\.spec) == ["h"])
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
            run       = "close-window"
            """)

        #expect(configuration.windowRules.isEmpty)
        #expect(configuration.problems.contains { $0.kind == .invalidRule })
    }

    // i3 の assign 相当。置き場所を固定できる。
    @Test("run に move-node-to-workspace を書ける")
    func ruleCanAssignWorkspace() throws {
        let configuration = try ConfigLoader.parse(
            """
            [[window-rule]]
            if-app-id = "com.example.app"
            run       = "move-node-to-workspace 3"
            """)

        #expect(!configuration.problems.contains { $0.kind == .invalidRule })
        #expect(configuration.windowRules.count == 1)
        #expect(configuration.windowRules[0].action == .moveToWorkspace(3))
    }

    @Test("行き先の番号が読めなければ問題として記録する")
    func ruleWorkspaceMustBeANumber() throws {
        let configuration = try ConfigLoader.parse(
            """
            [[window-rule]]
            if-app-id = "com.example.app"
            run       = "move-node-to-workspace web"
            """)

        #expect(configuration.windowRules.isEmpty)
        #expect(configuration.problems.contains { $0.kind == .invalidRule })
    }

    @Test("タイトルを正規表現で判定できる")
    func ruleCanUseRegex() throws {
        let configuration = try ConfigLoader.parse(
            """
            [[window-rule]]
            if-window-title-regex = "^Picture in Picture$"
            run                   = "layout floating"
            """)

        #expect(!configuration.problems.contains { $0.kind == .invalidRule })
        #expect(configuration.windowRules.count == 1)
        #expect(configuration.windowRules[0].matches(bundleID: nil, title: "Picture in Picture"))
        #expect(
            !configuration.windowRules[0].matches(
                bundleID: nil, title: "My Picture in Picture window"),
            "^ と $ が効いている")
    }

    // 実行時に黙って空振りすると、当たらない理由が分からない。
    @Test("解釈できない正規表現は読み込みのときに弾く")
    func invalidRegexIsReported() throws {
        let configuration = try ConfigLoader.parse(
            """
            [[window-rule]]
            if-window-title-regex = "[unclosed"
            run                   = "layout floating"
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

/// キーの層（i3 の `mode "resize"`）。
///
/// **層の中では修飾キーなしのキーも奪う。** それが層の目的なので、
/// 「修飾キーが無い」警告はここでは出さない（`main` だけで出す）。
@Suite("キーの層")
struct ModeTests {

    @Test("複数の層を読める")
    func multipleModesAreParsed() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-r = "mode resize"

            [mode.resize.binding]
            h = "resize width -50"
            esc = "mode main"
            """)
        #expect(configuration.modes.keys.sorted() == ["main", "resize"])
        #expect(configuration.bindings.map(\.spec) == ["alt-r"])
        #expect(configuration.bindings.first?.commands == [.mode("resize")])
        #expect(configuration.modes["resize"]?.count == 2)
        #expect(configuration.problems.isEmpty, "\(configuration.problems.map(\.detail))")
    }

    /// **行き先の無い層は押しても何も起きない。** 綴り間違いだと分かるようにする。
    @Test("書かれていない層への移動は問題として記録する")
    func unknownModeTargetsAreReported() throws {
        let configuration = try ConfigLoader.parse(
            """
            [mode.main.binding]
            alt-r = "mode resiz"
            """)
        #expect(
            configuration.problems.contains {
                $0.kind == .invalidCommand && $0.detail.contains("[mode.resiz]")
            }, "\(configuration.problems.map(\.detail))")
    }

    @Test("既定設定はリサイズの層を持つ")
    func theDefaultConfigurationHasAResizeMode() throws {
        let configuration = try ConfigLoader.parse(Configuration.defaultTOML)
        let resize = try #require(configuration.modes["resize"])
        let commands = Dictionary(uniqueKeysWithValues: resize.map { ($0.spec, $0.commands) })

        #expect(commands["h"] == [.resize(.width, delta: -50)])
        #expect(commands["l"] == [.resize(.width, delta: 50)])
        #expect(commands["esc"] == [.mode("main")])
        #expect(commands["enter"] == [.mode("main")])
        // 入り口が main 側にあること。無いと層へ行けない。
        #expect(configuration.bindings.contains { $0.commands == [.mode("resize")] })
    }

    @Test("mode コマンドを解釈する")
    func modeCommandIsParsed() throws {
        #expect(try Command.parse("mode resize") == .mode("resize"))
        // i3 は引用符付きで書く。書き写されても通す。
        #expect(try Command.parse("mode \"resize\"") == .mode("resize"))
        #expect(try Command.parse("mode resize").description == "mode resize")
        #expect(throws: Command.ParseError.self) { try Command.parse("mode") }
        #expect(throws: Command.ParseError.self) { try Command.parse("mode a b") }
    }
}
