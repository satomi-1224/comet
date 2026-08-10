import CoreGraphics
import Testing

@testable import CometCore

/// ウィンドウ間および画面端との余白。
///
/// 座標は AX 系（左上原点・Y は下向き）で扱うため、**「上」は minY 側**。
@Suite("Gaps")
struct GapsTests {

    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test("外周ギャップは AX 座標系で上が minY 側に効く")
    func outerGapsUseTopLeftOrigin() {
        let gaps = Gaps(
            innerHorizontal: 0, innerVertical: 0,
            outerTop: 10, outerBottom: 20, outerLeft: 30, outerRight: 40)
        let usable = gaps.usableArea(in: screen)

        #expect(usable.minX == 30, "左")
        #expect(usable.minY == 10, "上（AX では minY 側）")
        #expect(usable.maxX == 960, "右")
        #expect(usable.maxY == 580, "下（AX では maxY 側）")
    }

    @Test("一律指定の簡易イニシャライザ")
    func uniformInitializer() {
        let gaps = Gaps(inner: 5, outer: 5)
        #expect(gaps.innerHorizontal == 5)
        #expect(gaps.innerVertical == 5)
        #expect(gaps.outerTop == 5)
        #expect(gaps.outerBottom == 5)
        #expect(gaps.outerLeft == 5)
        #expect(gaps.outerRight == 5)
    }

    @Test("zero は領域を変えない")
    func zeroGapsPreserveArea() {
        #expect(Gaps.zero.usableArea(in: screen) == screen)
    }

    // 負の寸法を持つ CGRect を作らないこと。`CGRect.width` は絶対値を返すため、
    // 負の寸法は下流で符号を失って発見しづらいバグになる。
    @Test("外周ギャップが領域より大きければ空になる")
    func oversizedOuterGapsCollapse() {
        let usable = Gaps(inner: 0, outer: 600).usableArea(in: screen)
        #expect(usable.width <= 0 || usable.height <= 0)
        #expect(usable.width >= 0 && usable.height >= 0, "負の寸法は作らない")
    }
}
