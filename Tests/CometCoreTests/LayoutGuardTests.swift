import CoreGraphics
import Testing

@testable import CometCore

/// レイアウトの見張り。
///
/// **「掴んで動かしたウィンドウが戻ってこない」**という報告から入れた。
/// 通知だけでは足りない（戻した直後の読み戻しでは目標に一致していたのに、
/// 数百 ms 後には掴んだ先に居た。そのあとは通知が来ない）ので、定期的に
/// 目標と実際を突き合わせる。強く戻す一方で、勝てない相手と押し合い続けない。
@Suite("レイアウトの見張り")
struct LayoutGuardTests {

    @Test("ずれていれば戻す")
    func restoresWhenOff() {
        var guardState = LayoutGuard()
        #expect(guardState.decide(1, now: 0) == .restore)
    }

    /// 直った時点で数え直すので、**普通に使っている限り諦めには至らない。**
    @Test("戻せた回数は数えない")
    func settlingResetsTheCount() {
        var guardState = LayoutGuard()
        for step in 0..<20 {
            #expect(guardState.decide(1, now: Double(step)) == .restore)
            guardState.settled(1)
        }
    }

    /// 文字セル単位でしかリサイズできない端末のように、**どうやっても目標に
    /// 落ち着かない相手**と延々押し合うと CPU とログを食い潰す。
    @Test("戻しても直らないなら一旦諦める")
    func givesUpAfterRepeatedFailures() {
        var guardState = LayoutGuard()
        for _ in 0..<LayoutGuard.maxAttempts {
            #expect(guardState.decide(1, now: 0) == .restore)
        }
        #expect(guardState.decide(1, now: 0) == .giveUp)
        // 諦めを伝えるのは1回だけ。以後は黙って見送る。
        #expect(guardState.decide(1, now: 0) == .wait)
        #expect(guardState.decide(1, now: LayoutGuard.backoff - 1) == .wait)
    }

    @Test("休み明けにはまた戻しにいく")
    func retriesAfterBackoff() {
        var guardState = LayoutGuard()
        for _ in 0..<LayoutGuard.maxAttempts { _ = guardState.decide(1, now: 0) }
        #expect(guardState.decide(1, now: 0) == .giveUp)
        #expect(guardState.decide(1, now: LayoutGuard.backoff) == .restore)
    }

    @Test("諦めは窓ごとに数える")
    func stateIsPerWindow() {
        var guardState = LayoutGuard()
        for _ in 0...LayoutGuard.maxAttempts { _ = guardState.decide(1, now: 0) }
        #expect(guardState.decide(2, now: 0) == .restore)
    }

    // MARK: - ずれの判定

    /// **位置だけでなく大きさも見る。** 掴んで広げられたウィンドウを
    /// 「動いていない」と判定すると戻らない。
    @Test("位置か大きさが違えばずれとみなす")
    func detectsBothMoveAndResize() {
        let desired = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(!LayoutGuard.isOff(desired, from: desired))
        #expect(LayoutGuard.isOff(desired.offsetBy(dx: 40, dy: 0), from: desired))
        #expect(
            LayoutGuard.isOff(
                CGRect(x: 100, y: 100, width: 900, height: 600), from: desired))
    }

    /// アプリ側の丸めで 1pt ずれる程度で押し合わない。
    @Test("わずかなずれは見逃す")
    func toleratesRounding() {
        let desired = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(!LayoutGuard.isOff(desired.offsetBy(dx: 1, dy: -1), from: desired))
    }
}
