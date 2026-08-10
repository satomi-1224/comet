import Darwin
import Foundation

/// AX 適用のレイテンシをアプリ別に集計する。
///
/// **「どのアプリが足を引っ張っているか」を即座に分かるようにする**のが目的
/// （設計書 §11.3）。症状が再発したときの調査コストが桁で変わる。
///
/// - Important: 記録は **PID ごとのキュー上**から呼ばれるので、内部はロックで守る。
///   無効時は最初の判定で抜けるので、ロックも割り当ても起きない。
public final class TimingRecorder: @unchecked Sendable {

    public struct Summary: Equatable, Sendable {
        public let operation: String
        public let pid: pid_t
        /// 保持している標本の数。
        public let count: Int
        /// 受け取った総数。上限で捨てた分も含む。
        public let observed: Int
        /// ミリ秒。
        public let p50: Double
        public let p95: Double
        public let p99: Double
        public let maximum: Double
    }

    private struct Key: Hashable {
        let operation: String
        let pid: pid_t
    }

    /// 固定長の環状バッファ。何日も動くプロセスなので標本は増え続けさせない。
    private struct Samples {
        private var values: [Double]
        private var next = 0
        private(set) var observed = 0
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = max(1, capacity)
            self.values = []
            self.values.reserveCapacity(self.capacity)
        }

        mutating func append(_ value: Double) {
            observed += 1
            if values.count < capacity {
                values.append(value)
            } else {
                values[next] = value
                next = (next + 1) % capacity
            }
        }

        var sorted: [Double] { values.sorted() }
        var count: Int { values.count }
    }

    public let isEnabled: Bool
    private let capacity: Int
    private let lock = NSLock()
    private var samples: [Key: Samples] = [:]

    /// - Parameter capacity: 1つの系列で保持する標本の上限。
    public init(isEnabled: Bool, capacity: Int = 1024) {
        self.isEnabled = isEnabled
        self.capacity = capacity
    }

    // MARK: - 記録

    public func record(_ operation: String, pid: pid_t, seconds: Double) {
        guard isEnabled, seconds.isFinite, seconds >= 0 else { return }
        let key = Key(operation: operation, pid: pid)

        lock.lock()
        defer { lock.unlock() }
        if samples[key] == nil {
            samples[key] = Samples(capacity: capacity)
        }
        samples[key]?.append(seconds * 1000)
    }

    /// 実行時間を測りつつ本体を呼ぶ。無効なら計測せずに呼ぶだけ。
    public func measure<T>(_ operation: String, pid: pid_t, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = body()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        record(operation, pid: pid, seconds: Double(elapsed) / 1_000_000_000)
        return result
    }

    // MARK: - 取り出し

    /// 件数の多い順。同数なら操作名・PID で安定させる。
    public func summaries() -> [Summary] {
        lock.lock()
        let snapshot = samples
        lock.unlock()

        return snapshot.map { key, samples in
            let values = samples.sorted
            return Summary(
                operation: key.operation,
                pid: key.pid,
                count: samples.count,
                observed: samples.observed,
                p50: Self.percentile(values, 0.50),
                p95: Self.percentile(values, 0.95),
                p99: Self.percentile(values, 0.99),
                maximum: values.last ?? 0)
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.operation != $1.operation { return $0.operation < $1.operation }
            return $0.pid < $1.pid
        }
    }

    /// ログへ出せる形に整える。
    ///
    /// - Parameter appName: PID からアプリ名を引く。分からなければ `nil` を返してよい。
    public func report(appName: (pid_t) -> String?) -> [String] {
        summaries().map { summary in
            let name = appName(summary.pid).map { " (\($0))" } ?? ""
            let dropped = summary.observed > summary.count ? " of \(summary.observed)" : ""
            return "\(summary.operation) pid=\(summary.pid)\(name)"
                + " p50=\(format(summary.p50))ms p95=\(format(summary.p95))ms"
                + " p99=\(format(summary.p99))ms max=\(format(summary.maximum))ms"
                + " n=\(summary.count)\(dropped)"
        }
    }

    public func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    // MARK: - 内部

    /// 最近順位法（nearest-rank）。標本が少なくても破綻しない。
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
