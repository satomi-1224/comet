import Foundation
import os

/// プロセス全体で共有するロガー。
///
/// 出力先は2系統。
/// - **標準エラー**: 端末から起動したときに直接見える。開発中の主経路。
/// - **統一ログ**: `.app` として launchd から起動されると stderr はどこにも出ないため、
///   `log stream --predicate 'subsystem == "local.comet"'` で追えるようにしておく。
///
/// メッセージは `@autoclosure` で受けるので、しきい値で弾かれる場合は
/// 文字列生成そのものが起きない。ホットパスに `Log.shared.trace(...)` を置いても安全。
public final class Log: @unchecked Sendable {

    public static let shared = Log()

    /// しきい値の読み書きはログ呼び出しのたびに発生するため、
    /// NSLock ではなく os_unfair_lock ベースのものを使う。
    private let thresholdLock = OSAllocatedUnfairLock(initialState: LogLevel.info)

    /// 出力の直列化と DateFormatter の保護を兼ねる。
    private let writeLock = NSLock()

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private let osLog = os.Logger(subsystem: "local.comet", category: "comet")

    public init() {
        // **行ごとに書き出させる。** launchd などで stderr がファイルへ向くと
        // ブロックバッファになり、ログが遅れて見える。常駐プロセスの様子を
        // `tail` で追えないと状態を誤読する（実際に「まだ待機中」と読み違えた）。
        setvbuf(stderr, nil, _IOLBF, 0)
    }

    public var threshold: LogLevel {
        get { thresholdLock.withLock { $0 } }
        set { thresholdLock.withLock { $0 = newValue } }
    }

    public func isEnabled(_ level: LogLevel) -> Bool {
        LogLevel.isEnabled(level, threshold: threshold)
    }

    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        line: Int = #line
    ) {
        guard isEnabled(level) else { return }
        emit(level, message(), file: file, line: line)
    }

    public func trace(
        _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line
    ) {
        log(.trace, message(), file: file, line: line)
    }

    public func debug(
        _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line
    ) {
        log(.debug, message(), file: file, line: line)
    }

    public func info(
        _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line
    ) {
        log(.info, message(), file: file, line: line)
    }

    public func warn(
        _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line
    ) {
        log(.warn, message(), file: file, line: line)
    }

    public func error(
        _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line
    ) {
        log(.error, message(), file: file, line: line)
    }

    private func emit(_ level: LogLevel, _ message: String, file: String, line: Int) {
        // 統一ログ側。privacy: .public を付けないと <private> に伏せられる。
        switch level {
        case .trace, .debug: osLog.debug("\(message, privacy: .public)")
        case .info: osLog.info("\(message, privacy: .public)")
        case .warn: osLog.notice("\(message, privacy: .public)")
        case .error: osLog.error("\(message, privacy: .public)")
        case .off: break
        }

        writeLock.lock()
        let timestamp = formatter.string(from: Date())
        // fputs は例外を投げず、パイプが閉じていても静かに失敗する。
        fputs("\(timestamp) \(level.tag) [\(file):\(line)] \(message)\n", stderr)
        writeLock.unlock()
    }
}
