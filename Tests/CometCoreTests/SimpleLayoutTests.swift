import CoreGraphics
import Testing

@testable import CometCore

/// Phase 1 の暫定レイアウト（spiral）。Phase 2 で BSP ツリーに置き換える。
///
/// 座標は全て AX 系（左上原点・Y は下向き）。したがって「上」は minY 側。
@Suite("SimpleLayout / Gaps")
struct SimpleLayoutTests {

    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func spiral(_ count: Int, gaps: Gaps = .zero, in area: CGRect? = nil) -> [CGRect] {
        SimpleLayout.spiral(count: count, in: area ?? screen, gaps: gaps)
    }

    // MARK: - Gaps

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

    @Test("外周ギャップが領域より大きければ空になる")
    func oversizedOuterGapsCollapse() {
        let usable = Gaps(inner: 0, outer: 600).usableArea(in: screen)
        #expect(usable.width <= 0 || usable.height <= 0)
    }

    // MARK: - 形状

    @Test("ウィンドウが無ければ何も返さない")
    func zeroWindows() {
        #expect(spiral(0).isEmpty)
        #expect(spiral(-1).isEmpty)
    }

    @Test("1枚なら利用可能領域いっぱいになる")
    func singleWindowFillsUsableArea() {
        let gaps = Gaps(inner: 5, outer: 10)
        #expect(spiral(1, gaps: gaps) == [gaps.usableArea(in: screen)])
    }

    // 横長の領域では最初の分割が左右になる（AeroSpace の default-root-container-orientation = auto 相当）。
    @Test("2枚は左右に並ぶ")
    func twoWindowsSplitLeftRight() {
        let rects = spiral(2)
        #expect(rects.count == 2)
        #expect(rects[0].minY == rects[1].minY, "上端が揃う")
        #expect(rects[0].height == rects[1].height, "高さが揃う")
        #expect(rects[0].maxX <= rects[1].minX, "左右に並ぶ")
        #expect(rects[0].width == 500)
        #expect(rects[1].width == 500)
    }

    // 3枚目は2枚目の領域を上下に割る。
    @Test("3枚なら右側が上下に分かれる")
    func threeWindowsStackOnTheRight() {
        let rects = spiral(3)
        #expect(rects.count == 3)

        let left = rects[0]
        let topRight = rects[1]
        let bottomRight = rects[2]

        #expect(left.height == screen.height, "左は全高")
        #expect(topRight.minX == bottomRight.minX, "右の2枚は左端が揃う")
        #expect(topRight.width == bottomRight.width, "右の2枚は幅が揃う")
        #expect(topRight.maxY <= bottomRight.minY, "上下に並ぶ")
        #expect(topRight.minX >= left.maxX, "左より右にある")
    }

    // 既定は dwindle。新しいウィンドウは常に手前側を取り、残り領域が右下へ降りていく。
    @Test("4枚なら最後の2枚が横並びになる")
    func fourWindowsEndSideBySide() {
        let rects = spiral(4)
        #expect(rects.count == 4)

        let left = rects[0]
        let topRight = rects[1]
        let third = rects[2]
        let fourth = rects[3]

        #expect(left.height == screen.height, "左は全高")
        #expect(topRight.width == third.width + fourth.width, "下段が上段の幅を分け合う")
        #expect(third.minY == fourth.minY, "最後の2枚は上端が揃う")
        #expect(third.height == fourth.height, "最後の2枚は高さが揃う")
        #expect(third.minY >= topRight.maxY, "上段より下にある")
        #expect(third.maxX <= fourth.minX, "3枚目が左、4枚目が右")
    }

    // dwindle では新しいウィンドウが常に手前側を取るので、
    // 残り領域（＝最後のウィンドウが入る場所）は右下へ降りていく。
    @Test("dwindle では残り領域が右下へ降りていく")
    func dwindleMarchesTowardBottomRight() {
        let rects = SimpleLayout.spiral(count: 6, in: screen, gaps: .zero, style: .dwindle)
        for (previous, next) in zip(rects, rects.dropFirst()) {
            #expect(
                next.minX >= previous.minX && next.minY >= previous.minY,
                "左や上へ戻らない: \(previous) → \(next)")
        }
    }

    // 渦にするには、分割の向きだけでなく「どちら側を取るか」も反転させる必要がある。
    //
    //   ┌─────┬─────┐   A 左 → B 右上 → C 右下の右 → D その下 → E その上
    //   │     │  B  │   残り領域が 右→下→左→上 と時計回りに巻き込む
    //   │  A  ├──┬──┤
    //   │     │E │  │
    //   │     ├──┤C │
    //   │     │D │  │
    //   └─────┴──┴──┘
    @Test("spiral では残り領域が時計回りに巻き込む")
    func spiralWindsInward() {
        let rects = SimpleLayout.spiral(count: 5, in: screen, gaps: .zero, style: .spiral)
        #expect(rects.count == 5)

        let a = rects[0], b = rects[1], c = rects[2], d = rects[3], e = rects[4]

        #expect(a.height == screen.height, "A は全高")
        #expect(b.minX >= a.maxX, "B は A の右")
        #expect(c.minY >= b.maxY, "C は B の下")
        #expect(c.minX >= d.maxX, "C は D の右（3枚目が奥側を取る）")
        #expect(d.minY >= e.maxY, "D は E の下（4枚目が奥側を取る）")
        #expect(d.minX == e.minX, "D と E は左端が揃う")
        #expect(d.width == e.width, "D と E は幅が揃う")
    }

    @Test("spiral は一方向へ寄り続けない")
    func spiralDoesNotDegenerateIntoStaircase() {
        let rects = SimpleLayout.spiral(count: 6, in: screen, gaps: .zero, style: .spiral)
        let movesBack = zip(rects, rects.dropFirst()).contains { previous, next in
            next.minX < previous.minX || next.minY < previous.minY
        }
        #expect(movesBack, "常に右下へ進むだけなら渦ではない")
    }

    @Test("どちらの style でも重なりは出ない", arguments: [SimpleLayout.Style.dwindle, .spiral])
    func bothStylesAvoidOverlap(style: SimpleLayout.Style) {
        let rects = SimpleLayout.spiral(
            count: 7, in: screen, gaps: Gaps(inner: 5, outer: 5), style: style)
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width == 0 || overlap.height == 0)
            }
        }
    }

    // 縦長の領域では最初の分割が上下になる。
    @Test("縦長の領域では最初の分割が上下になる")
    func tallAreaSplitsVerticallyFirst() {
        let tall = CGRect(x: 0, y: 0, width: 600, height: 1000)
        let rects = spiral(2, in: tall)
        #expect(rects[0].width == tall.width, "全幅")
        #expect(rects[0].maxY <= rects[1].minY, "上下に並ぶ")
    }

    // MARK: - 不変条件

    @Test("重なりが出ない", arguments: 1...8)
    func noOverlaps(count: Int) {
        let rects = spiral(count, gaps: Gaps(inner: 5, outer: 5))
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let overlap = rects[i].intersection(rects[j])
                #expect(
                    overlap.isNull || overlap.width == 0 || overlap.height == 0,
                    "\(i) と \(j) が重なっている: \(rects[i]) / \(rects[j])")
            }
        }
    }

    @Test("外周は利用可能領域にぴったり接する", arguments: 1...8)
    func edgesTouchUsableArea(count: Int) {
        let gaps = Gaps(inner: 5, outer: 5)
        let usable = gaps.usableArea(in: screen)
        let rects = spiral(count, gaps: gaps)

        #expect(rects.map(\.minX).min() == usable.minX, "左端")
        #expect(rects.map(\.maxX).max() == usable.maxX, "右端")
        #expect(rects.map(\.minY).min() == usable.minY, "上端")
        #expect(rects.map(\.maxY).max() == usable.maxY, "下端")
    }

    @Test("隣接する分割の間隔はギャップと厳密に一致する")
    func gapsAreExact() {
        let gaps = Gaps(inner: 5, outer: 5)
        let rects = spiral(4, gaps: gaps)

        // 左と右上のあいだ（水平方向の分割）
        #expect(rects[1].minX - rects[0].maxX == gaps.innerHorizontal)
        // 右上と右下のあいだ（垂直方向の分割）
        #expect(rects[2].minY - rects[1].maxY == gaps.innerVertical)
        // 右下の2枚のあいだ（水平方向の分割）
        #expect(rects[3].minX - rects[2].maxX == gaps.innerHorizontal)
    }

    @Test("全ての矩形は 0.5pt 格子に載る", arguments: 1...8)
    func rectsSitOnRetinaGrid(count: Int) {
        let area = CGRect(x: 0, y: 0, width: 1001, height: 601)
        let rects = SimpleLayout.spiral(
            count: count, in: area, gaps: Gaps(inner: 5, outer: 5), scale: 2)
        for rect in rects {
            #expect(rect.minX * 2 == (rect.minX * 2).rounded())
            #expect(rect.maxX * 2 == (rect.maxX * 2).rounded())
            #expect(rect.minY * 2 == (rect.minY * 2).rounded())
            #expect(rect.maxY * 2 == (rect.maxY * 2).rounded())
        }
    }

    @Test("領域が狭すぎる場合は何も返さない")
    func tooSmallAreaYieldsNothing() {
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(spiral(3, gaps: Gaps(inner: 5, outer: 20), in: tiny).isEmpty)
    }

    // 分割を重ねると領域が尽きる。負の寸法を返してはいけない。
    @Test("領域が尽きても負の寸法にならない")
    func neverProducesNegativeSize() {
        let area = CGRect(x: 0, y: 0, width: 120, height: 120)
        let rects = SimpleLayout.spiral(count: 24, in: area, gaps: Gaps(inner: 5, outer: 5))
        for rect in rects {
            #expect(rect.width >= 0)
            #expect(rect.height >= 0)
        }
    }

    @Test("要求した枚数だけ返す", arguments: 1...12)
    func returnsRequestedCount(count: Int) {
        #expect(spiral(count, gaps: Gaps(inner: 5, outer: 5)).count == count)
    }

    // MARK: - 分割ごとの比率

    // 利用者がウィンドウの縁をドラッグしたら、それは分割境界を動かしたということ。
    // 比率を持たせておかないと「隣が追従して隙間は一定」が表現できない。
    @Test("分割ごとに比率を指定できる")
    func perSplitRatios() {
        let result = SimpleLayout.compute(
            count: 3, in: screen, gaps: .zero, ratios: [0.7, 0.25])
        #expect(result.rects[0].width == 700, "1つ目の分割は 0.7")
        #expect(result.rects[1].height == 150, "2つ目の分割は 0.25")
        #expect(result.rects[2].height == 450, "残りが下に来る")
    }

    @Test("比率が足りなければ既定値で補う")
    func missingRatiosFallBack() {
        let withRatios = SimpleLayout.compute(count: 4, in: screen, gaps: .zero, ratios: [0.5])
        let withoutRatios = SimpleLayout.compute(count: 4, in: screen, gaps: .zero)
        #expect(withRatios.rects == withoutRatios.rects)
    }

    @Test("分割の記録は枚数-1個で、境界が矩形の縁と一致する")
    func splitRecordsMatchRectEdges() {
        let gaps = Gaps(inner: 5, outer: 5)
        let result = SimpleLayout.compute(count: 4, in: screen, gaps: gaps)

        #expect(result.splits.count == 3)
        // 1つ目の分割の境界は、1枚目の右端
        #expect(result.splits[0].boundary == result.rects[0].maxX)
        // 2つ目は2枚目の下端
        #expect(result.splits[1].boundary == result.rects[1].maxY)
        // 3つ目は3枚目の右端
        #expect(result.splits[2].boundary == result.rects[2].maxX)
    }

    // 動いた辺から比率を逆算できないと、リサイズを分割へ反映できない。
    @Test("境界の位置から比率を逆算できる")
    func ratioIsRecoverableFromBoundary() {
        let result = SimpleLayout.compute(count: 2, in: screen, gaps: .zero, ratios: [0.5])
        let split = result.splits[0]
        #expect(split.ratio(forBoundary: split.boundary) == 0.5)
        #expect(split.ratio(forBoundary: screen.minX + 700) == 0.7)
    }

    @Test("逆算した比率を渡すと同じ配置になる")
    func recoveredRatioReproducesLayout() {
        let original = SimpleLayout.compute(count: 3, in: screen, gaps: Gaps(inner: 5, outer: 5))
        let recovered = original.splits.compactMap { $0.ratio(forBoundary: $0.boundary) }
        let reproduced = SimpleLayout.compute(
            count: 3, in: screen, gaps: Gaps(inner: 5, outer: 5), ratios: recovered)
        #expect(reproduced.rects == original.rects)
    }

    // MARK: - 最小寸法の尊重

    // アプリには縮められない下限がある（実測: Chrome の最小高さは 469pt）。
    // 下限を無視して割り当てると、そのウィンドウが隣にはみ出して重なる。
    // 下限を渡したら、兄弟が譲って間隔が保たれること。
    @Test("最小寸法を持つウィンドウには少なくともその寸法が割り当てられる")
    func minimumSizeIsRespected() {
        let minimums = [CGSize(width: 800, height: 0), .zero]
        let rects = SimpleLayout.spiral(count: 2, in: screen, gaps: .zero, minimums: minimums)
        #expect(rects[0].width >= 800)
        #expect(rects[1].width == screen.width - rects[0].width, "兄弟が譲る")
    }

    @Test("後続のウィンドウの最小寸法も考慮される")
    func laterMinimumShrinksEarlierWindow() {
        let minimums = [.zero, CGSize(width: 800, height: 0)]
        let rects = SimpleLayout.spiral(count: 2, in: screen, gaps: .zero, minimums: minimums)
        #expect(rects[1].width >= 800, "後ろのウィンドウが下限を確保する")
        #expect(rects[0].width <= 200)
    }

    @Test("最小寸法が満たせるなら重なりも隙間も出ない")
    func minimumSizeKeepsGapsExact() {
        let gaps = Gaps(inner: 5, outer: 5)
        let minimums = [.zero, .zero, CGSize(width: 0, height: 500), .zero]
        let rects = SimpleLayout.spiral(count: 4, in: screen, gaps: gaps, minimums: minimums)

        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width == 0 || overlap.height == 0)
            }
        }
        let usable = gaps.usableArea(in: screen)
        #expect(rects.map(\.maxX).max() == usable.maxX)
        #expect(rects.map(\.maxY).max() == usable.maxY)
    }

    // 全員の下限を同時に満たせないことはある。片方だけ満たすと、割を食った側が
    // 一方的にはみ出す。比例配分にして不足を分け合う。
    @Test("最小寸法を同時に満たせない場合は比例配分になる")
    func impossibleMinimumsAreSharedProportionally() {
        let minimums = [CGSize(width: 800, height: 0), CGSize(width: 800, height: 0)]
        let rects = SimpleLayout.spiral(count: 2, in: screen, gaps: .zero, minimums: minimums)
        #expect(rects[0].width == 500, "半々に分け合う")
        #expect(rects[1].width == 500)
    }

    @Test("最小寸法の配列が短くても落ちない")
    func shortMinimumsArrayIsTolerated() {
        let rects = SimpleLayout.spiral(
            count: 4, in: screen, gaps: .zero, minimums: [CGSize(width: 700, height: 0)])
        #expect(rects.count == 4)
        #expect(rects[0].width >= 700)
    }

    @Test("最小寸法を渡さなければ従来どおり")
    func emptyMinimumsPreserveBehavior() {
        #expect(spiral(4, gaps: Gaps(inner: 5, outer: 5))
            == SimpleLayout.spiral(count: 4, in: screen, gaps: Gaps(inner: 5, outer: 5), minimums: []))
    }

    // 範囲外の比率は「手前側が領域内に収まる」という分割の前提を壊す。
    @Test("範囲外の分割比は丸められる", arguments: [-1.0, 0.0, 1.0, 2.0] as [CGFloat])
    func outOfRangeRatioIsClamped(ratio: CGFloat) {
        let rects = SimpleLayout.spiral(count: 4, in: screen, gaps: .zero, ratio: ratio)
        #expect(rects.count == 4)
        for rect in rects {
            #expect(rect.width >= 0)
            #expect(rect.height >= 0)
            #expect(rect.minX >= screen.minX)
            #expect(rect.maxX <= screen.maxX)
            #expect(rect.minY >= screen.minY)
            #expect(rect.maxY <= screen.maxY)
        }
    }
}
