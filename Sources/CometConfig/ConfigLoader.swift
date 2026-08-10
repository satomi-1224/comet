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
                isTimingEnabled: configuration.performance.isTimingEnabled)
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
                    ?? configuration.border.focusedColor)

            // 「タイル全部に枠を描く」は未対応。書いてあるのに効かないと分からないので伝える。
            if border.colorUnfocused != nil {
                problems.append(
                    Problem(
                        kind: .unsupportedOption,
                        detail: "[border] color-unfocused はまだ未対応（フォーカス中だけに枠を描く）"))
            }
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

        if let wallpaper = raw.wallpaper, wallpaper.enabled ?? true {
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

        let bindings = parseBindings(raw.mode, problems: &problems)
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
        configuration.bindings = bindings
        configuration.windowRules = parseWindowRules(raw.windowRule, problems: &problems)
        configuration.problems = problems
        return configuration
    }

    // MARK: - バインド

    private static func parseBindings(
        _ modes: [String: RawMode]?, problems: inout [Problem]
    ) -> [Binding] {
        guard let modes else { return [] }

        // main 以外のモード（リサイズモード等）は Phase 5 以降。黙って落とさない。
        for name in modes.keys.sorted() where name != "main" {
            problems.append(
                Problem(kind: .unsupportedMode, detail: "[mode.\(name)] はまだ未対応なので読み飛ばした"))
        }
        guard let binding = modes["main"]?.binding else { return [] }

        var result: [Binding] = []
        // 辞書の並びは実行ごとに変わる。ログと重複検出が揺れないようキー順に固定する。
        for spec in binding.keys.sorted() {
            guard let specs = binding[spec]?.values else { continue }

            let hotkey: Hotkey
            do {
                hotkey = try KeySpec.parse(spec)
            } catch {
                problems.append(
                    Problem(kind: .invalidBinding, detail: "\(spec) を解釈できない: \(error)"))
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
            guard rule.ifAppID != nil || rule.ifWindowTitleSubstring != nil else {
                problems.append(
                    Problem(kind: .invalidRule, detail: "\(label): 条件が無い（全ウィンドウに当たってしまう）"))
                continue
            }
            guard rule.run == "layout floating" else {
                problems.append(
                    Problem(
                        kind: .invalidRule,
                        detail: "\(label): run に指定できるのは \"layout floating\" のみ（\(rule.run)）"))
                continue
            }
            result.append(
                WindowRule(
                    appID: rule.ifAppID, titleSubstring: rule.ifWindowTitleSubstring,
                    action: .float))
        }
        return result
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
    var gaps: RawGaps?
    var performance: RawPerformance?
    var debug: RawDebug?
    var border: RawBorder?
    var indicator: RawIndicator?
    var wallpaper: RawWallpaper?
    var mode: [String: RawMode]?
    var windowRule: [RawWindowRule]?

    enum CodingKeys: String, CodingKey {
        case startAtLogin = "start-at-login"
        case normalization, layout, workspaces, gaps, performance, debug
        case border, indicator, wallpaper, mode
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

private struct RawWallpaper: Decodable {
    var enabled: Bool?
    /// TOML のキーは文字列なので、番号への変換は読み込み側で行う。
    var map: [String: String]?
}

private struct RawWorkspaces: Decodable {
    var count: Int?
    var hidden: String?
    var focusFollowsActivation: Bool?

    enum CodingKeys: String, CodingKey {
        case count, hidden
        case focusFollowsActivation = "focus-follows-activation"
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
    var disableEnhancedUI: Bool?

    enum CodingKeys: String, CodingKey {
        case axTimeoutMS = "ax-timeout-ms"
        case applyIntervalMS = "apply-interval-ms"
        case maxCorrectionRetries = "max-correction-retries"
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
    var run: String

    enum CodingKeys: String, CodingKey {
        case ifAppID = "if-app-id"
        case ifWindowTitleSubstring = "if-window-title-substring"
        case run
    }
}
