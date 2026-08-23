import CoreGraphics
import Testing

@testable import CometCore

/// 追従しないウィンドウをフローティングへ降格させるかの判定。
///
/// **実機で「Safari のウィンドウが勝手に浮く」を踏んで入れた。**
/// 最小寸法の学習（`Engine.learnMinimum`）と降格が同じ条件で走っていたため、
/// 学習した 76ms 後に同じ理由で降格し、学習が打ち消されていた。
@Suite("フローティングへの降格")
struct FloatingDemotionTests {

    private let threshold: CGFloat = 50

    private func demote(_ target: CGRect, _ observed: CGRect) -> Bool {
        FloatingDemotion.shouldDemote(target: target, observed: observed, threshold: threshold)
    }

    /// 実測（Safari）: 幅 476 を要求すると 574 で止まる。**最小寸法があるだけ。**
    /// 学習した下限は次の再配置に効くので、降格させる理由が無い。
    @Test("最小寸法で目標より大きくなっただけなら降格しない")
    func aMinimumSizeIsNotAReasonToDemote() {
        let target = CGRect(x: 962, y: 270, width: 476, height: 239)
        let observed = CGRect(x: 962, y: 270, width: 574, height: 239)
        #expect(!demote(target, observed))
        #expect(FloatingDemotion.growthShortfall(target: target, observed: observed) == 0)
    }

    /// 実測（ターミナル）: 高さ 964 を要求すると 959 で止まる（文字セル単位）。
    @Test("文字セル単位への丸めでは降格しない")
    func cellQuantizationIsNotAReasonToDemote() {
        #expect(
            !demote(
                CGRect(x: 962, y: 28, width: 955, height: 964),
                CGRect(x: 962, y: 28, width: 955, height: 959)))
    }

    /// **位置を無視するアプリはタイル配置として成立しない。**
    /// 実測では、位置を先に設定しないと幅が画面端で切り詰められる例があった。
    @Test("位置を無視するなら降格する")
    func ignoringThePositionDemotes() {
        #expect(
            demote(
                CGRect(x: 5, y: 61, width: 1273, height: 1598),
                CGRect(x: 1707, y: 61, width: 1273, height: 1598)))
    }

    @Test("要求より大幅に小さいまま広がらないなら降格する")
    func refusingToGrowDemotes() {
        #expect(
            demote(
                CGRect(x: 0, y: 0, width: 1200, height: 800),
                CGRect(x: 0, y: 0, width: 1200, height: 400)))
    }

    /// 歯止めが効いていることの確認。境界のちょうどでは降格しない。
    @Test("しきい値までは降格しない")
    func staysBelowTheThreshold() {
        let target = CGRect(x: 0, y: 0, width: 1200, height: 800)
        #expect(!demote(target, CGRect(x: 0, y: 0, width: 1200, height: 750)))
        #expect(demote(target, CGRect(x: 0, y: 0, width: 1200, height: 749)))
        #expect(!demote(target, CGRect(x: 50, y: 0, width: 1200, height: 800)))
        #expect(demote(target, CGRect(x: 51, y: 0, width: 1200, height: 800)))
    }
}
