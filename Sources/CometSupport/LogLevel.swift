import Foundation

/// ログの重要度。`off` はしきい値としてのみ意味を持ち、メッセージのレベルにはならない。
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case trace = 0
    case debug = 1
    case info = 2
    case warn = 3
    case error = 4
    case off = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var name: String {
        switch self {
        case .trace: "trace"
        case .debug: "debug"
        case .info: "info"
        case .warn: "warn"
        case .error: "error"
        case .off: "off"
        }
    }

    /// ログ出力時に桁を揃えるための固定幅表記。
    public var tag: String {
        switch self {
        case .trace: "TRC"
        case .debug: "DBG"
        case .info: "INF"
        case .warn: "WRN"
        case .error: "ERR"
        case .off: "OFF"
        }
    }

    public init?(name: String) {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "trace": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "warn", "warning": self = .warn
        case "error": self = .error
        case "off": self = .off
        default: return nil
        }
    }

    /// `level` のメッセージを `threshold` の下で出力すべきか。
    ///
    /// ログ呼び出しのたびに評価されるため純粋関数として切り出してある。
    /// `threshold == .off` なら全て抑制、`level == .off` は常に無効。
    public static func isEnabled(_ level: LogLevel, threshold: LogLevel) -> Bool {
        level != .off && level.rawValue >= threshold.rawValue
    }
}
