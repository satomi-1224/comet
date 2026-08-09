import Dispatch
import Foundation
import Testing

@testable import CometAccessibility

@Suite("ApplierPool")
struct ApplierPoolTests {

    @Test("同じ PID には同じキューを返す")
    func sameQueueForSamePID() {
        let pool = ApplierPool()
        let a = pool.queue(for: 1234)
        let b = pool.queue(for: 1234)
        #expect(a === b)
    }

    @Test("異なる PID には別のキューを返す")
    func distinctQueuesForDistinctPIDs() {
        let pool = ApplierPool()
        #expect(pool.queue(for: 1) !== pool.queue(for: 2))
    }

    @Test("キューのラベルに PID が入る")
    func queueLabelContainsPID() {
        let pool = ApplierPool()
        #expect(pool.queue(for: 4321).label.contains("4321"))
    }

    @Test("count は保持しているキュー数を反映する")
    func countReflectsState() {
        let pool = ApplierPool()
        #expect(pool.count == 0)
        _ = pool.queue(for: 1)
        _ = pool.queue(for: 1)
        #expect(pool.count == 1)
        _ = pool.queue(for: 2)
        #expect(pool.count == 2)
    }

    @Test("removeQueue で破棄され、次は新しいキューになる")
    func removeQueue() {
        let pool = ApplierPool()
        let first = pool.queue(for: 99)
        pool.removeQueue(for: 99)
        #expect(pool.count == 0)
        let second = pool.queue(for: 99)
        #expect(first !== second)
    }

    @Test("removeAll で全て破棄される")
    func removeAll() {
        let pool = ApplierPool()
        for pid in pid_t(1)...pid_t(8) { _ = pool.queue(for: pid) }
        #expect(pool.count == 8)
        pool.removeAll()
        #expect(pool.count == 0)
    }

    @Test("存在しない PID の削除は無害")
    func removeMissingPIDIsHarmless() {
        let pool = ApplierPool()
        pool.removeQueue(for: 777)
        #expect(pool.count == 0)
    }

    // ウィンドウ生成通知は複数スレッドから同時に届きうる。
    // 同一 PID に対してキューが二重生成されると、そのアプリ宛の
    // AX 呼び出しが並列化してしまい順序保証が壊れる。
    @Test("同一 PID への同時アクセスでもキューは1本だけ")
    func concurrentSamePIDYieldsOneQueue() {
        let pool = ApplierPool()
        let iterations = 512
        let lock = NSLock()
        nonisolated(unsafe) var collected: [DispatchQueue] = []
        collected.reserveCapacity(iterations)

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let q = pool.queue(for: 42)
            lock.lock()
            collected.append(q)
            lock.unlock()
        }

        #expect(pool.count == 1)
        #expect(collected.count == iterations)
        let first = collected[0]
        #expect(collected.allSatisfy { $0 === first }, "同一 PID に複数のキューが生成された")
    }

    @Test("複数 PID への同時アクセスで PID ごとに1本ずつ")
    func concurrentDistinctPIDs() {
        let pool = ApplierPool()
        let pidCount = 64
        DispatchQueue.concurrentPerform(iterations: pidCount * 8) { i in
            _ = pool.queue(for: pid_t(i % pidCount))
        }
        #expect(pool.count == pidCount)
    }

    @Test("生成と削除が同時に走ってもクラッシュしない")
    func concurrentCreateAndRemove() {
        let pool = ApplierPool()
        DispatchQueue.concurrentPerform(iterations: 512) { i in
            let pid = pid_t(i % 16)
            if i.isMultiple(of: 2) {
                _ = pool.queue(for: pid)
            } else {
                pool.removeQueue(for: pid)
            }
        }
        #expect(pool.count <= 16)
    }

    @Test("返されたキューは実際に処理を実行できる")
    func queueExecutes() {
        let pool = ApplierPool()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ran = false
        pool.queue(for: 1).async {
            ran = true
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(ran)
    }

    // 各アプリ宛の呼び出しは順序が保証されなければならない。
    // 例: 「サイズ設定 → 位置設定」が入れ替わると中間状態が画面に出る。
    @Test("同一 PID のキューは直列である")
    func queueIsSerial() {
        let pool = ApplierPool()
        let queue = pool.queue(for: 1)
        let lock = NSLock()
        nonisolated(unsafe) var order: [Int] = []
        let group = DispatchGroup()

        for i in 0..<200 {
            group.enter()
            queue.async {
                lock.lock()
                order.append(i)
                lock.unlock()
                group.leave()
            }
        }

        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(order == Array(0..<200), "投入順に実行されていない")
    }
}
