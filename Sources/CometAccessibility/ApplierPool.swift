import Darwin
import Dispatch
import Foundation

/// アプリ（PID）ごとの直列キューを管理する。
///
/// AX API の呼び出しは対象アプリのメインスレッドとの**同期 IPC** であり、
/// 相手がビジーなら呼び出し側スレッドがブロックする。ただしこのシリアライズは
/// プロセス単位でしか起きないため、**異なるアプリ宛の呼び出しは真に並列実行できる**。
/// PID ごとにキューを分けることでその並列性を取りに行く。
///
/// 各キューが**直列**であることは必須。同一ウィンドウへの
/// 「サイズ設定 → 位置設定」が入れ替わると中間状態が画面に出る。
public final class ApplierPool: @unchecked Sendable {

    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]
    private let qos: DispatchQoS

    public init(qos: DispatchQoS = .userInteractive) {
        self.qos = qos
    }

    /// 指定 PID 向けのキューを返す。無ければ生成する。
    ///
    /// 生成をロック内で行うのは、同一 PID に対してキューが二重生成されると
    /// そのアプリ宛の呼び出しが並列化して順序保証が壊れるため。
    public func queue(for pid: pid_t) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let existing = queues[pid] { return existing }
        let created = DispatchQueue(label: "comet.ax.\(pid)", qos: qos)
        queues[pid] = created
        return created
    }

    /// アプリ終了時に呼ぶ。存在しない PID を渡しても無害。
    public func removeQueue(for pid: pid_t) {
        lock.lock()
        queues.removeValue(forKey: pid)
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return queues.count
    }

    public func removeAll() {
        lock.lock()
        queues.removeAll()
        lock.unlock()
    }
}
