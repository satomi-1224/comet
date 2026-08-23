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

/// 「もう寄せ切れない」と分かった姿に落ち着いているかの判定。
///
/// **実機で見つけた発振を止めるために入れた。** 端末（ターミナル.app）は文字セル
/// 単位でしかリサイズできないため、要求 955x964 に対して実測 955x959 で止まる。
/// 補正が3回で諦めたあと、見張りが「2pt より大きくずれている」と判定して戻しに行き、
/// また諦める、が 20 秒周期で永久に続いた（47 秒で 13 回、約 52 回の AX 往復）。
@Suite("寄せ切れない相手との押し合いを止める")
struct SettledAtLimitTests {

    private let desired = CGRect(x: 962, y: 28, width: 955, height: 964)
    /// 実機で観測した「端末が落ち着く姿」。高さが 5pt 足りない。
    private let actual = CGRect(x: 962, y: 28, width: 955, height: 959)

    @Test("諦めた実績が無ければ、ずれは戻す対象")
    func withoutHistoryItIsStillOff() {
        #expect(LayoutGuard.isOff(actual, from: desired))
        #expect(!LayoutGuard.isSettledAtLimit(actual: actual, desired: desired, tolerated: nil))
    }

    @Test("同じ目標で同じ姿に落ち着いたなら、それが限界")
    func sameTargetAndSameActualIsSettled() {
        #expect(
            LayoutGuard.isSettledAtLimit(
                actual: actual, desired: desired,
                tolerated: (target: desired, actual: actual)))
    }

    /// **目標が変わったら試し直す。** 前の目標に届かなかったことは、
    /// 新しい目標に届かない理由にはならない（ギャップ変更や隣の増減で寸法は変わる）。
    @Test("目標が変わったら限界の記憶は効かない")
    func aNewTargetIsRetried() {
        let moved = desired.offsetBy(dx: 0, dy: 40)
        #expect(
            !LayoutGuard.isSettledAtLimit(
                actual: actual, desired: moved,
                tolerated: (target: desired, actual: actual)))
    }

    /// **掴んで動かされたら戻す。** 限界の記憶があっても、実測がその姿から
    /// 離れたなら利用者か他のアプリが動かしたということ。
    @Test("実測が限界の姿から離れたら戻す")
    func aMovedWindowIsStillRestored() {
        let dragged = actual.offsetBy(dx: 200, dy: 0)
        #expect(
            !LayoutGuard.isSettledAtLimit(
                actual: dragged, desired: desired,
                tolerated: (target: desired, actual: actual)))
    }

    /// アプリ側の丸めで 1pt 程度は毎回ぶれる。ここで厳密比較にすると
    /// 記憶が一度も効かず、押し合いが止まらない。
    @Test("1pt のぶれは同じ姿とみなす")
    func subPixelJitterIsTheSameShape() {
        let jittered = CGRect(
            x: actual.minX, y: actual.minY, width: actual.width, height: actual.height + 1)
        #expect(
            LayoutGuard.isSettledAtLimit(
                actual: jittered, desired: desired,
                tolerated: (target: desired, actual: actual)))
    }
}
