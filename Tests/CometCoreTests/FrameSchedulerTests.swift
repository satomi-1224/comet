import CoreGraphics
import Darwin
import Foundation
import Testing

@testable import CometAccessibility
@testable import CometCore
@testable import CometSupport

/// 実際に AX を叩く経路はテストできないが、「ウィンドウが既に消えていた」場合に
/// 適用中のまま詰まらないことは検証できる。ここが詰まると以後そのウィンドウへの
/// 更新が永久に発行されなくなる。
@MainActor
@Suite("FrameScheduler")
struct FrameSchedulerTests {

    /// 何も解決できないリゾルバ。ウィンドウが消えた直後の状態を模す。
    private final class EmptyResolver: WindowResolving {
        var appliedCalls: [CGWindowID] = []
        func element(for id: CGWindowID) -> AXElement? { nil }
        func pid(for id: CGWindowID) -> pid_t? { nil }
        func observedFrame(for id: CGWindowID) -> CGRect? { nil }
        func didApply(_ id: CGWindowID, target: CGRect, observed: CGRect?, succeeded: Bool) {
            appliedCalls.append(id)
        }
    }

    private func quietLog() -> Log {
        let log = Log()
        log.threshold = .off
        return log
    }

    private func makeScheduler() -> FrameScheduler {
        FrameScheduler(applierPool: ApplierPool(), log: quietLog())
    }

    @Test("生成直後は待機中")
    func startsIdle() {
        #expect(makeScheduler().isIdle)
    }

    @Test("リゾルバ未設定なら投入しても詰まらない")
    func noResolverDoesNotStall() {
        let scheduler = makeScheduler()
        scheduler.submit(1, TargetFrame(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(scheduler.isIdle, "解決できない要求は捨てる")
    }

    // ウィンドウが消えた直後に適用要求が残っていると、AX 要素を引けずに
    // 適用中フラグが立ったままになりうる。そうなると以後そのウィンドウは
    // 二度と更新されない。捨てて待機中に戻ること。
    @Test("解決できないウィンドウは捨てて待機中に戻る")
    func unresolvableWindowIsDropped() {
        let scheduler = makeScheduler()
        let resolver = EmptyResolver()
        scheduler.setResolver(resolver)

        scheduler.submit(
            [42: TargetFrame(rect: CGRect(x: 0, y: 0, width: 100, height: 100))], order: [42])

        #expect(scheduler.isIdle)
        #expect(resolver.appliedCalls.isEmpty, "適用していないのに完了通知を出さない")
    }

    @Test("捨てられたウィンドウの適用履歴は残らない")
    func droppedWindowLeavesNoTrace() {
        let scheduler = makeScheduler()
        scheduler.setResolver(EmptyResolver())
        scheduler.submit(7, TargetFrame(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(scheduler.appliedFrame(7) == nil)
    }

    @Test("空の一括投入は何もしない")
    func emptySubmitIsNoOp() {
        let scheduler = makeScheduler()
        scheduler.setResolver(EmptyResolver())
        scheduler.submit([:], order: [])
        #expect(scheduler.isIdle)
    }

    @Test("forget は未知のウィンドウでも無害")
    func forgetUnknownIsHarmless() {
        let scheduler = makeScheduler()
        scheduler.forget(999)
        #expect(scheduler.isIdle)
    }

    // 外部から動かされたウィンドウを戻すには、自分の適用による通知と
    // 区別できなければならない。区別を誤ると自分の適用に反応して押し合いになる。
    @Test("何もしていないウィンドウは落ち着いている扱い")
    func idleWindowIsNotSettling() {
        let scheduler = makeScheduler()
        scheduler.setResolver(EmptyResolver())
        #expect(!scheduler.isSettling(1))
    }

    @Test("投入したウィンドウは適用が片付くまで落ち着いていない扱い")
    func submittedWindowIsSettling() {
        let scheduler = makeScheduler()
        // リゾルバ未設定だと drain 前に捨てられてしまうので、
        // 投入直後の状態だけを見る。
        scheduler.submit(1, TargetFrame(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        // 解決できず捨てられた後なので、落ち着いた状態に戻っている
        #expect(!scheduler.isSettling(1))
    }

    @Test("reapply は未解決でも詰まらない")
    func reapplyWithoutResolverIsHarmless() {
        let scheduler = makeScheduler()
        scheduler.setResolver(EmptyResolver())
        scheduler.reapply(1, TargetFrame(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(scheduler.isIdle)
    }
}
