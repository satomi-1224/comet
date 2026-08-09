import CoreGraphics
import Testing

@testable import CometCore

/// macOS には原点の異なる2つの座標系が併存する。
///
/// - AppKit: プライマリの**左下**が原点、Y は上向き（`NSScreen.frame`）
/// - CG / AX: プライマリの**左上**が原点、Y は下向き（`CGDisplayBounds`, `kAXPosition`）
///
/// comet は内部状態を全て CG/AX 座標系で持ち、AppKit に渡す直前だけ変換する。
@Suite("Geometry")
struct GeometryTests {

    // プライマリが 1000pt 高いとする（AppKit 座標での上端 = 1000）
    private let primaryMaxY: CGFloat = 1000

    @Test("AppKit の最上段は AX では y = 0")
    func topOfScreenMapsToZero() {
        let appKit = CGRect(x: 0, y: 900, width: 100, height: 100)  // 上端に接する
        let ax = Geometry.toAX(appKit, primaryMaxY: primaryMaxY)
        #expect(ax == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("AppKit の最下段は AX では y = 画面高 - 高さ")
    func bottomOfScreenMapsToBottom() {
        let appKit = CGRect(x: 0, y: 0, width: 100, height: 100)  // 下端に接する
        let ax = Geometry.toAX(appKit, primaryMaxY: primaryMaxY)
        #expect(ax == CGRect(x: 0, y: 900, width: 100, height: 100))
    }

    @Test("X と寸法は変換で変わらない")
    func horizontalIsUnchanged() {
        let appKit = CGRect(x: 137, y: 400, width: 321, height: 210)
        let ax = Geometry.toAX(appKit, primaryMaxY: primaryMaxY)
        #expect(ax.origin.x == 137)
        #expect(ax.size == appKit.size)
    }

    @Test(
        "変換は往復する",
        arguments: [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: -500, y: 250, width: 800, height: 600),
            CGRect(x: 137.5, y: 400.25, width: 321, height: 210),
        ])
    func roundTrips(rect: CGRect) {
        let ax = Geometry.toAX(rect, primaryMaxY: primaryMaxY)
        #expect(Geometry.toAppKit(ax, primaryMaxY: primaryMaxY) == rect)
    }

    // プライマリより上に置いた外部モニタは AX 座標で負の y になる。
    @Test("プライマリより上の領域は AX で負の y になる")
    func regionAbovePrimaryIsNegative() {
        let appKit = CGRect(x: 0, y: 1000, width: 1920, height: 1080)
        let ax = Geometry.toAX(appKit, primaryMaxY: primaryMaxY)
        #expect(ax.origin.y == -1080)
    }

    // MARK: - 丸め

    @Test(
        "Retina では 0.5pt 単位に丸める",
        arguments: [
            (100.3, 100.5), (100.1, 100.0), (100.0, 100.0),
            (100.24, 100.0), (100.26, 100.5), (99.9, 100.0),
        ])
    func roundsToRetinaGrid(input: CGFloat, expected: CGFloat) {
        #expect(Geometry.rounded(input, scale: 2) == expected)
    }

    @Test("scale 1 では整数に丸める")
    func roundsToIntegerAtScaleOne() {
        #expect(Geometry.rounded(100.4, scale: 1) == 100)
        #expect(Geometry.rounded(100.6, scale: 1) == 101)
    }

    @Test("負の値も正しく丸める")
    func roundsNegativeValues() {
        #expect(Geometry.rounded(-100.3, scale: 2) == -100.5)
        #expect(Geometry.rounded(-100.1, scale: 2) == -100.0)
    }

    @Test("scale が 0 以下なら丸めない")
    func invalidScaleIsNoOp() {
        #expect(Geometry.rounded(100.37, scale: 0) == 100.37)
        #expect(Geometry.rounded(100.37, scale: -2) == 100.37)
    }

    @Test("矩形の丸めは原点と終端の両方を格子に載せる")
    func roundsRectEdges() {
        let rect = CGRect(x: 10.3, y: 20.1, width: 100.4, height: 50.4)
        let rounded = Geometry.rounded(rect, scale: 2)
        #expect(rounded.minX == 10.5)
        #expect(rounded.minY == 20.0)
        // 終端も格子上にあること（幅を丸めるのではなく終端を丸める）
        #expect(rounded.maxX == Geometry.rounded(rect.maxX, scale: 2))
        #expect(rounded.maxY == Geometry.rounded(rect.maxY, scale: 2))
    }

    // MARK: - 近似比較

    @Test("許容誤差内の矩形は等しいとみなす")
    func approximateEquality() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 0.3, y: -0.2, width: 100.4, height: 99.8)
        #expect(Geometry.isApproximatelyEqual(a, b, tolerance: 0.5))
    }

    @Test("許容誤差を超えたら等しくない")
    func approximateEqualityFails() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 0, y: 0, width: 101, height: 100)
        #expect(!Geometry.isApproximatelyEqual(a, b, tolerance: 0.5))
    }

    @Test("許容誤差ちょうどは等しいとみなす")
    func toleranceBoundaryIsInclusive() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 0.5, y: 0, width: 100, height: 100)
        #expect(Geometry.isApproximatelyEqual(a, b, tolerance: 0.5))
    }
}
