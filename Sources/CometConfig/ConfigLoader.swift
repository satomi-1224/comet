import CoreGraphics
import Foundation
import TOMLDecoder
import CometCore
import CometInput
import CometSupport

/// `~/.config/comet/config.toml` を読む。
///
/// 方針は**「1箇所の誤りで全体を落とさない」**。解釈できなかった項目は既定値に落として
/// `Configuration.problems` に理由を積む。TOML そのものが壊れている場合だけは
/// 何を採用すべきか判断できないので失敗させる。
public enum ConfigLoader {

    public enum Source: Equatable, Sendable {
        case file(String)
        case builtIn
    }

    /// 設定ファイルの既定の場所。`XDG_CONFIG_HOME` を尊重する。
    public static func defaultPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let base = environment["XDG_CONFIG_HOME"], !base.isEmpty {
            return "\(base)/comet/config.toml"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/comet/config.toml"
    }

    /// ファイルから読む。無ければ組み込みの既定を使う。**投げない。**
    public static func load(path: String = defaultPath()) -> (
        configuration: Configuration, source: Source
    ) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (builtIn(), .builtIn)
        }
        do {
            return (try parse(text), .file(path))
        } catch {
            var configuration = builtIn()
            configuration.problems.append(
                Problem(kind: .unreadable, detail: "\(path) を解釈できなかった: \(error)"))
            return (configuration, .builtIn)
        }
    }

    /// 組み込みの既定設定。
    public static func builtIn() -> Configuration {
        // 既定が読めないのは実装側の誤り。テストで検出できるようにしてあるので、
        // ここでは素の既定値へ落として起動だけは続ける。
        (try? parse(Configuration.defaultTOML)) ?? Configuration()
    }

    public static func parse(_ toml: String) throws -> Configuration {
        let raw = try TOMLDecoder().decode(RawConfiguration.self, from: toml)

        var configuration = Configuration()
        var problems: [Problem] = []

        if let gaps = raw.gaps {
            // 負のギャップは境界を領域の外へ押し出してウィンドウを重ねる。
            // 打ち間違いで壊れた配置になるより、下限で止めて理由を残すほうがよい。
            func gap(_ value: CGFloat?, _ fallback: CGFloat, _ label: String) -> CGFloat {
                guard let value else { return fallback }
                return clamped(value, to: 0...10_000, label: "[gaps] \(label)", &problems)
            }
            configuration.gaps = Gaps(
                innerHorizontal: gap(
                    gaps.innerHorizontal, configuration.gaps.innerHorizontal, "inner-horizontal"),
                innerVertical: gap(
                    gaps.innerVertical, configuration.gaps.innerVertical, "inner-vertical"),
                outerTop: gap(gaps.outerTop, configuration.gaps.outerTop, "outer-top"),
                outerBottom: gap(gaps.outerBottom, configuration.gaps.outerBottom, "outer-bottom"),
                outerLeft: gap(gaps.outerLeft, configuration.gaps.outerLeft, "outer-left"),
                outerRight: gap(gaps.outerRight, configuration.gaps.outerRight, "outer-right"))
        }

        if let normalization = raw.normalization {
            configuration.normalization = NormalizationConfig(
                flattenContainers: normalization.flattenContainers
                    ?? configuration.normalization.flattenContainers,
                oppositeOrientationForNested: normalization.oppositeOrientationNested
                    ?? configuration.normalization.oppositeOrientationForNested)
        }

        if let layout = raw.layout {
            if let value = layout.defaultOrientation {
                if let parsed = DefaultOrientation(rawValue: value) {
                    configuration.defaultOrientation = parsed
                } else {
                    problems.append(
                        Problem(
                            kind: .invalidValue,
                            detail: "[layout] default-orientation の値が不明: \(value)"
                                + "（候補: \(names(of: DefaultOrientation.allCases))）"))
                }
            }
            if let value = layout.insertion {
                if let parsed = TreeSync.InsertionStrategy(rawValue: value) {
                    configuration.insertionStrategy = parsed
                } else {
                    problems.append(
                        Problem(
                            kind: .invalidValue,
                            detail: "[layout] insertion の値が不明: \(value)"
                                + "（候補: \(names(of: TreeSync.InsertionStrategy.allCases))）"))
                }
            }
        }

        configuration.startAtLogin = raw.startAtLogin ?? configuration.startAtLogin

        if let workspaces = raw.workspaces {
            if let value = workspaces.count {
                // 0 個だと有効なワークスペースが存在しない。上限はキーバインドの現実的な数。
                configuration.workspaceCount = clamped(
                    value, to: 1...36, label: "[workspaces] count", &problems)
            }
            configuration.focusFollowsActivation =
                workspaces.focusFollowsActivation ?? configuration.focusFollowsActivation
            configuration.workspaceAutoBackAndForth =
                workspaces.autoBackAndForth ?? configuration.workspaceAutoBackAndForth

            for (key, name) in workspaces.names ?? [:] {
                guard let id = Int(key), id >= 1 else {
                    problems.append(
                        Problem(
                            kind: .invalidValue,
                            detail: "[workspaces.names] のキーはワークスペース番号（1 以上）: \(key)"))
                    continue
                }
                configuration.workspaceNames[id] = name
            }

            if let value = workspaces.hidden {
                if let parsed = HiddenWindowStrategy(rawValue: value) {
                    configuration.hiddenWindowStrategy = parsed
                } else {
                    problems.append(
                        Problem(
                            kind: .invalidValue,
                            detail: "[workspaces] hidden の値が不明: \(value)"
                                + "（候補: \(names(of: HiddenWindowStrategy.allCases))）"))
                }
            }
        }

        if let value = raw.monitors?.manage {
            if let parsed = MonitorScope(rawValue: value) {
                configuration.monitorScope = parsed
            } else {
                problems.append(
                    Problem(
                        kind: .invalidValue,
                        detail: "[monitors] manage の値が不明: \(value)"
                            + "（候補: \(names(of: MonitorScope.allCases))）"))
            }
        }

        if let value = raw.debug?.logLevel {
            if let parsed = LogLevel(name: value) {
                configuration.logLevel = parsed
            } else {
                problems.append(
                    Problem(kind: .invalidValue, detail: "[debug] log-level の値が不明: \(value)"))
            }
        }

        if let performance = raw.performance {
            let fallback = configuration.performance
            // 極端な値は「遅い」ではなく「壊れる」方向に効く。
            // 適用間隔 0 は待たずに回り続けて CPU を焼き、AX タイムアウト 0 は
            // 全てのウィンドウ操作を失敗させる。
            configuration.performance = PerformanceOptions(
                axTimeout: performance.axTimeoutMS.map {
                    clamped($0 / 1000, to: 0.01...5, label: "[performance] ax-timeout-ms", &problems)
                } ?? fallback.axTimeout,
                applyInterval: performance.applyIntervalMS.map {
                    clamped(
                        $0 / 1000, to: 0.001...1, label: "[performance] apply-interval-ms",
                        &problems)
                } ?? fallback.applyInterval,
                maxCorrections: performance.maxCorrectionRetries.map {
                    clamped(
                        $0, to: 0...20, label: "[performance] max-correction-retries", &problems)
                } ?? fallback.maxCorrections,
                disablesEnhancedUserInterface: performance.disableEnhancedUI
                    ?? fallback.disablesEnhancedUserInterface,
                isTimingEnabled: configuration.performance.isTimingEnabled,
                repeatDelay: performance.repeatDelayMS.map {
                    clamped(
                        $0 / 1000, to: 0.05...2, label: "[performance] repeat-delay-ms", &problems)
                } ?? fallback.repeatDelay,
                repeatInterval: performance.repeatIntervalMS.map {
                    clamped(
                        $0 / 1000, to: 0.008...1, label: "[performance] repeat-interval-ms",
                        &problems)
                } ?? fallback.repeatInterval)
        }

        // `[debug] timing` は `[performance]` の有無に関わらず読む。
        // 片方のセクションが無いと読まれない、という結び付きを作らない。
        if let value = raw.debug?.timing {
            configuration.performance.isTimingEnabled = value
        }

        if let border = raw.border {
            configuration.border = BorderStyle(
                isEnabled: border.enabled ?? configuration.border.isEnabled,
                width: border.width.map {
                    clamped($0, to: 0...50, label: "[border] width", &problems)
                } ?? configuration.border.width,
                radius: border.radius.map {
                    clamped($0, to: 0...100, label: "[border] radius", &problems)
                } ?? configuration.border.radius,
                focusedColor: color(
                    border.colorFocused, "[border] color-focused", &problems)
                    ?? configuration.border.focusedColor,
                unfocusedColor: color(
                    border.colorUnfocused, "[border] color-unfocused", &problems))
        }

        if let indicator = raw.indicator {
            if let value = indicator.style {
                if let parsed = IndicatorStyle(rawValue: value) {
                    configuration.indicator = parsed
                } else {
                    problems.append(
                        Problem(
                            kind: .invalidValue,
                            detail: "[indicator] style の値が不明: \(value)"
                                + "（候補: \(names(of: IndicatorStyle.allCases))）"))
                }
            }
            if let value = indicator.hudDurationMS {
                configuration.hudDuration = clamped(
                    value / 1000, to: 0.05...5, label: "[indicator] hud-duration-ms", &problems)
            }
        }

        if let focus = raw.focus {
            if let value = focus.cycleResetMS {
                // 0 は「毎回組み直す」という意味なので下限で切り上げない。
                configuration.focusCycleReset = clamped(
                    value / 1000, to: 0...10, label: "[focus] cycle-reset-ms", &problems)
            }
            configuration.focusFollowsMouse = focus.followsMouse ?? configuration.focusFollowsMouse
            configuration.focusWrapping = focus.wrapping ?? configuration.focusWrapping
            if let value = focus.cycleScope {
                if let scope = FocusCycleScope(rawValue: value) {
                    configuration.focusCycleScope = scope
                } else {
                    problems.append(
                        Problem(
                            kind: .invalidValue,
                            detail: "[focus] cycle-scope は "
                                + FocusCycleScope.allCases.map(\.rawValue).joined(separator: " / ")
                                + " のいずれか: \(value)"))
                }
            }
        }

        if let wallpaper = raw.wallpaper, wallpaper.enabled ?? true {
            if let dir = wallpaper.dir, !dir.trimmingCharacters(in: .whitespaces).isEmpty {
                configuration.wallpaperDirectory = dir
            }
            for (key, path) in wallpaper.map ?? [:] {
                guard let workspace = Int(key), workspace >= 1 else {
                    problems.append(
                        Problem(
                            kind: .invalidValue,
                            detail: "[wallpaper.map] のキーはワークスペース番号（1 以上）: \(key)"))
                    continue
                }
                configuration.wallpapers[workspace] = path
            }
        }

        let modes = parseModes(raw.mode, problems: &problems)
        configuration.modes = modes
        let bindings = configuration.bindings
        if bindings.isEmpty {
            // 設定ファイルは既定を**置き換える**。`[gaps]` だけ書いた設定で
            // 全てのキーが効かなくなるのは分かりにくいので必ず知らせる。
            problems.append(
                Problem(
                    kind: .noBindings,
                    detail: "[mode.main.binding] が空。設定ファイルは既定を置き換えるので"
                        + "キーバインドは1つも登録されない"
                        + "（--print-default-config で全部入りの雛形を出せる）"))
        }
        // 書かれていないモードへ飛ぼうとするバインドは、押しても何も起きない。
        // **キーが効かない原因が綴り間違いだと分かるようにする。**
        for (mode, bindings) in modes.sorted(by: { $0.key < $1.key }) {
            for binding in bindings {
                for command in binding.commands {
                    guard case .mode(let target) = command, modes[target] == nil else { continue }
                    problems.append(
                        Problem(
                            kind: .invalidCommand,
                            detail: "[mode.\(mode).binding] \(binding.spec) の行き先 "
                                + "[mode.\(target)] が書かれていない"))
                }
            }
        }
        configuration.windowRules = parseWindowRules(raw.windowRule, problems: &problems)
        // **知らない項目名を最後に照合する。** `Decodable` は黙って捨てるので、
        // ここで拾わないと「設定したのに効かない」だけが残る。
        problems.append(contentsOf: ConfigSchema.unknownKeys(in: toml))
        configuration.problems = problems
        return configuration
    }

    // MARK: - バインド

    /// すべてのモードのバインドを読む。
    ///
    /// **モードは i3 の `mode "resize"` に相当する層。** `main` が既定で、
    /// `mode <名前>` コマンドで移る。
    private static func parseModes(
        _ modes: [String: RawMode]?, problems: inout [Problem]
    ) -> [String: [Binding]] {
        guard let modes else { return [:] }
        var result: [String: [Binding]] = [:]
        // 辞書の並びは実行ごとに変わる。ログと重複検出が揺れないよう名前順に固定する。
        for name in modes.keys.sorted() {
            guard let binding = modes[name]?.binding else { continue }
            result[name] = parseBindings(binding, mode: name, problems: &problems)
        }
        return result
    }

    private static func parseBindings(
        _ binding: [String: CommandSpec], mode: String, problems: inout [Problem]
    ) -> [Binding] {
        var result: [Binding] = []
        // 辞書の並びは実行ごとに変わる。ログと重複検出が揺れないようキー順に固定する。
        for spec in binding.keys.sorted() {
            guard let specs = binding[spec]?.values else { continue }

            let hotkey: Hotkey
            do {
                hotkey = try KeySpec.parse(spec)
            } catch {
                problems.append(
                    Problem(
                        kind: .invalidBinding,
                        detail: "[mode.\(mode).binding] \(spec) を解釈できない: \(error)"))
                continue
            }

            var commands: [Command] = []
            var failed = false
            for text in specs {
                do {
                    commands.append(try Command.parse(text))
                } catch let error as Command.ParseError {
                    // 未対応と綴り間違いを分けて報告する。分けないと、キーが効かない
                    // 原因が設定側か実装側か区別できない。
                    let kind: Problem.Kind =
                        if case .unsupported = error { .unsupportedCommand } else { .invalidCommand }
                    problems.append(Problem(kind: kind, detail: "\(spec) = \"\(text)\": \(error)"))
                    failed = true
                } catch {
                    problems.append(
                        Problem(kind: .invalidCommand, detail: "\(spec) = \"\(text)\": \(error)"))
                    failed = true
                }
            }
            // 配列の一部だけを実行すると中途半端な状態になる。全部そろって初めて登録する。
            guard !failed, !commands.isEmpty else { continue }
            result.append(Binding(spec: spec, hotkey: hotkey, commands: commands))
        }
        return result
    }

    // MARK: - ウィンドウルール

    private static func parseWindowRules(
        _ rules: [RawWindowRule]?, problems: inout [Problem]
    ) -> [WindowRule] {
        guard let rules else { return [] }

        var result: [WindowRule] = []
        for (index, rule) in rules.enumerated() {
            let label = "[[window-rule]] の \(index + 1) 番目"

            // 条件が空だと全ウィンドウに当たる。事故が大きいので拒否する。
            guard rule.ifAppID != nil || rule.ifWindowTitleSubstring != nil
                || rule.ifWindowTitleRegex != nil
            else {
                problems.append(
                    Problem(kind: .invalidRule, detail: "\(label): 条件が無い（全ウィンドウに当たってしまう）"))
                continue
            }
            // 正規表現は**読み込みのときに確かめる。** 実行時に黙って空振りすると、
            // 「ルールが当たらない」原因が綴りなのか条件なのか分からない。
            if let pattern = rule.ifWindowTitleRegex, !WindowRule.isValidRegex(pattern) {
                problems.append(
                    Problem(
                        kind: .invalidRule,
                        detail: "\(label): if-window-title-regex を正規表現として解釈できない: \(pattern)"))
                continue
            }
            guard let action = ruleAction(rule.run) else {
                problems.append(
                    Problem(
                        kind: .invalidRule,
                        detail: "\(label): run に指定できるのは \"layout floating\" と "
                            + "\"move-node-to-workspace <番号>\"（\(rule.run)）"))
                continue
            }
            result.append(
                WindowRule(
                    appID: rule.ifAppID, titleSubstring: rule.ifWindowTitleSubstring,
                    titleRegex: rule.ifWindowTitleRegex, action: action))
        }
        return result
    }

    /// `run` に書ける動作。**コマンドの綴りをそのまま使う。**
    ///
    /// 別の綴りを作ると「キーバインドでは動くのにルールでは書けない」ことになり、
    /// どちらの語彙を覚えればよいのか分からなくなる。
    private static func ruleAction(_ run: String) -> WindowRule.Action? {
        let tokens = run.split(whereSeparator: \.isWhitespace).map(String.init)
        switch tokens.first {
        case "layout":
            // i3 の `floating enable` も受ける。
            return tokens.dropFirst().first == "floating" ? .float : nil
        case "floating":
            return tokens.dropFirst().first == "enable" ? .float : nil
        case "move-node-to-workspace":
            guard tokens.count == 2, let id = Int(tokens[1]), id >= 1 else { return nil }
            return .moveToWorkspace(id)
        default:
            return nil
        }
    }

    private static func names<T: RawRepresentable>(of cases: [T]) -> String
    where T.RawValue == String {
        cases.map(\.rawValue).joined(separator: " | ")
    }

    /// 色を解釈する。書かれていなければ `nil`、書かれていて読めなければ問題として残す。
    private static func color(
        _ text: String?, _ label: String, _ problems: inout [Problem]
    ) -> RGBAColor? {
        guard let text else { return nil }
        guard let parsed = RGBAColor(hex: text) else {
            problems.append(
                Problem(
                    kind: .invalidValue,
                    detail: "\(label) を色として解釈できない: \(text)"
                        + "（#RGB / #RRGGBB / #RRGGBBAA）"))
            return nil
        }
        return parsed
    }

    /// 範囲外の値を端で止め、丸めたことを理由つきで残す。
    private static func clamped<T: Comparable>(
        _ value: T, to range: ClosedRange<T>, label: String, _ problems: inout [Problem]
    ) -> T {
        let result = min(max(value, range.lowerBound), range.upperBound)
        guard result != value else { return value }
        problems.append(
            Problem(
                kind: .invalidValue,
                detail: "\(label) は \(range.lowerBound)〜\(range.upperBound) の範囲に収める"
                    + "（\(value) → \(result) として扱う）"))
        return result
    }
}

// MARK: - TOML の生の形

/// 文字列 1 つでも配列でも受ける。`alt-shift-1 = ["...", "..."]` のため。
private enum CommandSpec: Decodable {
    case single(String)
    case multiple([String])

    init(from decoder: Decoder) throws {
        // TOMLDecoder は配列に対して singleValueContainer() 自体が投げる。
        // 単一値の取得を try? で包み、配列は unkeyedContainer から読む。
        if let one = try? decoder.singleValueContainer().decode(String.self) {
            self = .single(one)
            return
        }
        var container = try decoder.unkeyedContainer()
        var values: [String] = []
        while !container.isAtEnd {
            values.append(try container.decode(String.self))
        }
        self = .multiple(values)
    }

    var values: [String] {
        switch self {
        case .single(let value): [value]
        case .multiple(let values): values
        }
    }
}

private struct RawConfiguration: Decodable {
    var startAtLogin: Bool?
    var normalization: RawNormalization?
    var layout: RawLayout?
    var workspaces: RawWorkspaces?
    var monitors: RawMonitors?
    var gaps: RawGaps?
    var performance: RawPerformance?
    var debug: RawDebug?
    var border: RawBorder?
    var indicator: RawIndicator?
    var wallpaper: RawWallpaper?
    var focus: RawFocus?
    var mode: [String: RawMode]?
    var windowRule: [RawWindowRule]?

    enum CodingKeys: String, CodingKey {
        case startAtLogin = "start-at-login"
        case normalization, layout, workspaces, monitors, gaps, performance, debug
        case border, indicator, wallpaper, focus, mode
        case windowRule = "window-rule"
    }
}

private struct RawBorder: Decodable {
    var enabled: Bool?
    var width: CGFloat?
    var radius: CGFloat?
    var colorFocused: String?
    var colorUnfocused: String?

    enum CodingKeys: String, CodingKey {
        case enabled, width, radius
        case colorFocused = "color-focused"
        case colorUnfocused = "color-unfocused"
    }
}

private struct RawIndicator: Decodable {
    var style: String?
    var hudDurationMS: Double?

    enum CodingKeys: String, CodingKey {
        case style
        case hudDurationMS = "hud-duration-ms"
    }
}

private struct RawFocus: Decodable {
    var cycleResetMS: Double?
    var cycleScope: String?
    var followsMouse: Bool?
    var wrapping: Bool?

    enum CodingKeys: String, CodingKey {
        case cycleResetMS = "cycle-reset-ms"
        case cycleScope = "cycle-scope"
        case followsMouse = "follows-mouse"
        case wrapping
    }
}

private struct RawWallpaper: Decodable {
    var enabled: Bool?
    /// 画像を入れたディレクトリ。名前順にワークスペースへ割り当てる。
    var dir: String?
    /// TOML のキーは文字列なので、番号への変換は読み込み側で行う。
    var map: [String: String]?
}

private struct RawMonitors: Decodable {
    var manage: String?
}

private struct RawWorkspaces: Decodable {
    var count: Int?
    var hidden: String?
    var focusFollowsActivation: Bool?
    var autoBackAndForth: Bool?
    /// TOML のキーは文字列なので、番号への変換は読み込み側で行う。
    var names: [String: String]?

    enum CodingKeys: String, CodingKey {
        case count, hidden, names
        case focusFollowsActivation = "focus-follows-activation"
        case autoBackAndForth = "auto-back-and-forth"
    }
}

private struct RawNormalization: Decodable {
    var flattenContainers: Bool?
    var oppositeOrientationNested: Bool?

    enum CodingKeys: String, CodingKey {
        case flattenContainers = "flatten-containers"
        case oppositeOrientationNested = "opposite-orientation-nested"
    }
}

private struct RawLayout: Decodable {
    var defaultOrientation: String?
    var insertion: String?

    enum CodingKeys: String, CodingKey {
        case defaultOrientation = "default-orientation"
        case insertion
    }
}

private struct RawGaps: Decodable {
    var innerHorizontal: CGFloat?
    var innerVertical: CGFloat?
    var outerTop: CGFloat?
    var outerBottom: CGFloat?
    var outerLeft: CGFloat?
    var outerRight: CGFloat?

    enum CodingKeys: String, CodingKey {
        case innerHorizontal = "inner-horizontal"
        case innerVertical = "inner-vertical"
        case outerTop = "outer-top"
        case outerBottom = "outer-bottom"
        case outerLeft = "outer-left"
        case outerRight = "outer-right"
    }
}

private struct RawPerformance: Decodable {
    var axTimeoutMS: Double?
    var applyIntervalMS: Double?
    var maxCorrectionRetries: Int?
    var repeatDelayMS: Double?
    var repeatIntervalMS: Double?
    var disableEnhancedUI: Bool?

    enum CodingKeys: String, CodingKey {
        case axTimeoutMS = "ax-timeout-ms"
        case applyIntervalMS = "apply-interval-ms"
        case maxCorrectionRetries = "max-correction-retries"
        case repeatDelayMS = "repeat-delay-ms"
        case repeatIntervalMS = "repeat-interval-ms"
        case disableEnhancedUI = "disable-enhanced-ui"
    }
}

private struct RawDebug: Decodable {
    var logLevel: String?
    var timing: Bool?

    enum CodingKeys: String, CodingKey {
        case logLevel = "log-level"
        case timing
    }
}

private struct RawMode: Decodable {
    var binding: [String: CommandSpec]?
}

private struct RawWindowRule: Decodable {
    var ifAppID: String?
    var ifWindowTitleSubstring: String?
    var ifWindowTitleRegex: String?
    var run: String

    enum CodingKeys: String, CodingKey {
        case ifAppID = "if-app-id"
        case ifWindowTitleSubstring = "if-window-title-substring"
        case ifWindowTitleRegex = "if-window-title-regex"
        case run
    }
}
