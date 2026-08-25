import CoreGraphics
import Testing

@testable import CometCore

@Suite("フレーム補正の収束")
struct FrameCorrectionTrackerTests {

    private let target = CGRect(x: 10, y: 20, width: 800, height: 600)

    @Test("目標に一致すれば補正しない")
    func matchingFrameSettles() {
        var tracker = FrameCorrectionTracker()
        #expect(
            tracker.evaluate(
                1, target: target, observed: target, tolerance: 0.5, maxCorrections: 3)
                == .settled)
    }

    @Test("同じ実測が続いたら残りの補正を省く")
    func unchangedResultConvergesEarly() {
        var tracker = FrameCorrectionTracker()
        let observed = CGRect(x: 10, y: 20, width: 797, height: 602)

        #expect(
            tracker.evaluate(
                1, target: target, observed: observed, tolerance: 0.5,
                maxCorrections: 3) == .retry(1))
        #expect(
            tracker.evaluate(
                1, target: target, observed: observed, tolerance: 0.5,
                maxCorrections: 3) == .giveUp(.unchangedResult))
    }

    @Test("実測が変化している間は設定回数まで補正する")
    func changingResultUsesConfiguredRetries() {
        var tracker = FrameCorrectionTracker()
        for retry in 1...3 {
            let observed = target.offsetBy(dx: CGFloat(10 - retry), dy: 0)
            #expect(
                tracker.evaluate(
                    1, target: target, observed: observed, tolerance: 0.5,
                    maxCorrections: 3) == .retry(retry))
        }
        let final = target.offsetBy(dx: 6, dy: 0)
        #expect(
            tracker.evaluate(
                1, target: target, observed: final, tolerance: 0.5,
                maxCorrections: 3) == .giveUp(.exhausted))
    }

    @Test("目標が変われば補正回数を数え直す")
    func newTargetResetsAttempts() {
        var tracker = FrameCorrectionTracker()
        let observed = target.offsetBy(dx: 10, dy: 0)
        #expect(
            tracker.evaluate(
                1, target: target, observed: observed, tolerance: 0.5,
                maxCorrections: 3) == .retry(1))

        let newTarget = target.offsetBy(dx: 100, dy: 0)
        #expect(
            tracker.evaluate(
                1, target: newTarget, observed: observed, tolerance: 0.5,
                maxCorrections: 3) == .retry(1))
    }
}
