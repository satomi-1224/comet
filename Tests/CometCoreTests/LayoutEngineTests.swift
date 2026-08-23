import CoreGraphics
import Testing

@testable import CometCore

/// BSP ツリーから目標矩形を算出する純粋関数。**副作用は無い。**
///
/// 座標は全て AX 系（左上原点・Y は下向き）。したがって「上」は minY 側。
///
/// 丸めの方針:
/// **分割の境界だけを格子に載せ、最後の子の終端は領域の終端に固定する。**
/// こうすると間隔がギャップと厳密に一致し、外周も領域にぴったり接する。
@Suite("LayoutEngine")
struct LayoutEngineTests {

    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func h(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .horizontal, children: children)
    }

    private func v(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .vertical, children: children)
    }

    private func w(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    private func compute(
        _ root: ContainerNode,
        gaps: Gaps = .zero,
        in area: CGRect? = nil,
        scale: CGFloat = 2,
        minimums: [CGWindowID: CGSize] = [:]
    ) -> LayoutEngine.Result {
        LayoutEngine.compute(
            root: root, area: area ?? screen, gaps: gaps, scale: scale, minimums: minimums)
    }

    // MARK: - 退化した入力

    @Test("空のルートは何も返さない")
    func emptyRootProducesNothing() {
        let result = compute(ContainerNode(orientation: .horizontal))
        #expect(result.frames.isEmpty)
        #expect(result.order.isEmpty)
        #expect(result.boundaries.isEmpty)
    }

    @Test("領域が潰れていれば何も返さない")
    func degenerateAreaProducesNothing() {
        #expect(compute(h(w(1), w(2)), in: CGRect(x: 0, y: 0, width: 0, height: 600)).frames.isEmpty)
        #expect(compute(h(w(1)), gaps: Gaps(inner: 0, outer: 600)).frames.isEmpty)
    }

    // MARK: - 基本の分割

    @Test("1枚なら外周ギャップを除いた領域いっぱいになる")
    func singleWindowFillsAreaMinusOuterGaps() {
        let gaps = Gaps(inner: 5, outer: 10)
        let result = compute(h(w(1)), gaps: gaps)
        #expect(result.frames[1] == gaps.usableArea(in: screen))
        #expect(result.boundaries.isEmpty, "分割が無いので境界も無い")
    }

    @Test("均等な比率の左右分割")
    func horizontalSplitEqualWeights() {
        let result = compute(h(w(1), w(2)))
        #expect(result.frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(result.frames[2] == CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test("均等な比率の上下分割")
    func verticalSplitEqualWeights() {
        let result = compute(v(w(1), w(2)))
        #expect(result.frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 300))
        #expect(result.frames[2] == CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    @Test("比率どおりに配分される")
    func weightsAreRespected() {
        let root = h(w(1), w(2), w(3))
        root.setWeights([0.5, 0.3, 0.2])
        let result = compute(root)

        #expect(result.frames[1]?.width == 500)
        #expect(result.frames[2]?.width == 300)
        #expect(result.frames[3]?.width == 200)
    }

    @Test("入れ子は親の領域の中だけを分ける")
    func nestedContainerSplitsOnlyItsOwnArea() {
        let result = compute(h(w(1), v(w(2), w(3))))

        #expect(result.frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(result.frames[2] == CGRect(x: 500, y: 0, width: 500, height: 300))
        #expect(result.frames[3] == CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    // MARK: - ギャップ

    @Test("内側ギャップは兄弟の間だけに入る")
    func gapsAppliedBetweenSiblingsOnly() {
        let gaps = Gaps(inner: 10, outer: 0)
        // 幅 1010 なら間隔 2 本を除いた 990 が 3 で割り切れて、丸めが混ざらない。
        let area = CGRect(x: 0, y: 0, width: 1010, height: 600)
        let result = compute(h(w(1), w(2), w(3)), gaps: gaps, in: area)

        #expect(result.frames[1]?.minX == 0, "外周には触らない")
        #expect(result.frames[3]?.maxX == 1010)
        #expect(result.frames[1]?.maxX == 330)
        #expect(result.frames[2]?.minX == 340, "間隔ぶん空く")
        #expect(result.frames[2]?.maxX == 670)
        #expect(result.frames[3]?.minX == 680)
    }

    @Test("向きに応じて内側ギャップを使い分ける")
    func innerGapsAreAxisSpecific() {
        let gaps = Gaps(
            innerHorizontal: 20, innerVertical: 4,
            outerTop: 0, outerBottom: 0, outerLeft: 0, outerRight: 0)
        let result = compute(h(w(1), v(w(2), w(3))), gaps: gaps)

        let left = result.frames[1]!
        let top = result.frames[2]!
        let bottom = result.frames[3]!

        #expect(top.minX - left.maxX == 20, "左右は innerHorizontal")
        #expect(bottom.minY - top.maxY == 4, "上下は innerVertical")
    }

    @Test("外周ギャップは AX 座標系で上が minY 側に効く")
    func outerGapsUseTopLeftOrigin() {
        let gaps = Gaps(
            innerHorizontal: 0, innerVertical: 0,
            outerTop: 10, outerBottom: 20, outerLeft: 30, outerRight: 40)
        let result = compute(h(w(1)), gaps: gaps)

        #expect(result.frames[1] == CGRect(x: 30, y: 10, width: 930, height: 570))
    }

    // MARK: - 丸め

    @Test("最後の子が丸め誤差を吸収する")
    func lastChildAbsorbsRoundingError() {
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 600)
        let result = compute(h(w(1), w(2), w(3)), in: odd, scale: 1)

        let rects = [1, 2, 3].compactMap { result.frames[$0] }
        #expect(rects.count == 3)
        #expect(rects[0].maxX == rects[1].minX, "隙間も重なりも出ない")
        #expect(rects[1].maxX == rects[2].minX)
        #expect(rects[2].maxX == 1001, "右端は領域にぴったり接する")
    }

    @Test("全ての矩形は 0.5pt 格子に載る", arguments: [2, 3, 4, 5, 7])
    func allRectsSitOnTheGrid(count: Int) {
        let root = ContainerNode(orientation: .horizontal)
        var cursor = root
        // 深い入れ子を作り、丸めが累積する状況を作る。
        for id in 0..<count {
            cursor.append(w(CGWindowID(id + 1)))
            guard id < count - 1 else { break }
            let next = ContainerNode(orientation: cursor.orientation.flipped)
            cursor.append(next)
            cursor = next
        }

        let odd = CGRect(x: 0.25, y: 0, width: 1333, height: 777)
        let result = compute(root, gaps: Gaps(inner: 5, outer: 5), in: odd)

        for (id, rect) in result.frames {
            for value in [rect.minX, rect.minY, rect.maxX, rect.maxY] {
                #expect((value * 2).truncatingRemainder(dividingBy: 1) == 0, "[\(id)] \(rect)")
            }
        }
    }

    // MARK: - 網羅性（重なりも隙間も出ないこと）

    @Test("兄弟の間隔はギャップと厳密に一致する")
    func siblingSpacingMatchesGapExactly() {
        let gaps = Gaps(inner: 7, outer: 3)
        let root = h(w(1), w(2), v(w(3), w(4), w(5)))
        root.setWeights([0.2, 0.3, 0.5])
        let result = compute(root, gaps: gaps, in: CGRect(x: 0, y: 0, width: 1237, height: 831))

        #expect(result.frames[2]!.minX - result.frames[1]!.maxX == 7)
        #expect(result.frames[3]!.minX - result.frames[2]!.maxX == 7)
        #expect(result.frames[4]!.minY - result.frames[3]!.maxY == 7)
        #expect(result.frames[5]!.minY - result.frames[4]!.maxY == 7)
    }

    @Test("どの2枚も重ならない")
    func noTwoRectsOverlap() {
        let root = h(w(1), v(w(2), h(w(3), w(4))), v(w(5), w(6)))
        let result = compute(root, gaps: Gaps(inner: 5, outer: 5))

        let rects = Array(result.frames.values)
        for i in rects.indices {
            for j in rects.indices where j > i {
                #expect(!rects[i].intersects(rects[j]), "\(rects[i]) と \(rects[j])")
            }
        }
    }

    @Test("外周は領域にぴったり接する")
    func outerEdgesTouchTheArea() {
        let gaps = Gaps(inner: 5, outer: 8)
        let root = h(w(1), v(w(2), w(3)))
        let result = compute(root, gaps: gaps)
        let usable = gaps.usableArea(in: screen)

        let rects = Array(result.frames.values)
        #expect(rects.map(\.minX).min() == usable.minX)
        #expect(rects.map(\.maxX).max() == usable.maxX)
        #expect(rects.map(\.minY).min() == usable.minY)
        #expect(rects.map(\.maxY).max() == usable.maxY)
    }

    @Test("面積の合計は領域からギャップを引いたものに一致する")
    func areaSumMatchesAreaMinusGaps() {
        let gaps = Gaps(inner: 10, outer: 0)
        // H[1, V[2, 3]]: 縦の間隔 1 本と横の間隔 1 本ぶんが失われる。
        let result = compute(h(w(1), v(w(2), w(3))), gaps: gaps)

        let total = result.frames.values.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let lost = 10 * 600 + 10 * 495  // 縦の間隔（全高） + 横の間隔（右半分の幅）
        // #expect の中で整数式と CGFloat を比べると常に不一致になる。両辺を CGFloat に揃える。
        let expected = CGFloat(1000 * 600 - lost)
        #expect(total == expected)
    }

    // MARK: - 適用順

    @Test("適用順は葉の深さ優先順")
    func orderIsDepthFirst() {
        let result = compute(h(w(1), v(w(2), h(w(3), w(4))), w(5)))
        #expect(result.order == [1, 2, 3, 4, 5])
    }

    // MARK: - 分割境界

    @Test("境界の数は分割の数と一致する")
    func boundaryCountMatchesSplitCount() {
        // H に子3つ（境界2つ） + V に子2つ（境界1つ）
        let result = compute(h(w(1), w(2), v(w(3), w(4))))
        #expect(result.boundaries.count == 3)
    }

    @Test("境界は手前側の子の終端に置かれる")
    func boundarySitsAtLeadingChildTrailingEdge() throws {
        let gaps = Gaps(inner: 10, outer: 0)
        let result = compute(h(w(1), w(2)), gaps: gaps)

        let boundary = try #require(result.boundaries.first)
        #expect(boundary.orientation == .horizontal)
        #expect(boundary.leadingIndex == 0)
        #expect(boundary.gap == 10)
        #expect(boundary.position == result.frames[1]!.maxX)
        #expect(result.frames[2]!.minX == boundary.position + boundary.gap, "奥側は境界 + 間隔から始まる")
    }

    @Test("境界の移動量は比率の変化量へ直せる")
    func boundaryConvertsMovementToWeightDelta() throws {
        let gaps = Gaps(inner: 10, outer: 0)
        let result = compute(h(w(1), w(2)), gaps: gaps)
        let boundary = try #require(result.boundaries.first)

        // 配分できる長さは 1000 - 10 = 990。境界を 99pt 動かせば比率は 0.1 動く。
        #expect(boundary.available == 990)
        let delta = try #require(boundary.weightDelta(movingTo: boundary.position + 99))
        #expect(abs(delta - 0.1) < 1e-9, "\(delta)")
    }

    @Test("境界は自分が属するコンテナを指す")
    func boundaryPointsAtItsContainer() throws {
        let nested = v(w(2), w(3))
        let root = h(w(1), nested)
        let result = compute(root)

        let vertical = try #require(result.boundaries.first { $0.orientation == .vertical })
        #expect(vertical.container === nested)

        let horizontal = try #require(result.boundaries.first { $0.orientation == .horizontal })
        #expect(horizontal.container === root)
    }

    @Test("配分できる長さが 0 なら比率は求まらない")
    func boundaryWithoutAvailableLengthYieldsNoDelta() {
        // 間隔が領域と同じ幅なら、子に配れる長さが残らない。
        let result = compute(h(w(1), w(2)), gaps: Gaps(inner: 1000, outer: 0))
        if let boundary = result.boundaries.first {
            #expect(boundary.weightDelta(movingTo: 100) == nil)
        }
    }

    // MARK: - 動いた辺と境界の突き合わせ

    @Test("手前側のウィンドウの終端は境界そのもの")
    func leadingWindowTrailingEdgeMatchesBoundary() throws {
        let root = h(w(1), w(2))
        let result = compute(root, gaps: Gaps(inner: 10, outer: 0))
        let node = try #require(root.findWindow(1))

        // 配分できる長さは 1000 - 10 = 990。境界は 495 で、手前側の 1 の終端はそこにある。
        let match = try #require(
            result.match(edge: 495, of: node, orientation: .horizontal, tolerance: 2))
        #expect(match.edgeOffset == 0)
        #expect(match.boundary.container === root)
        #expect(match.boundaryPosition(forEdge: 600) == 600, "辺の位置がそのまま境界の位置になる")
    }

    @Test("奥側のウィンドウの始端は境界に間隔を足した位置")
    func trailingWindowLeadingEdgeIsBoundaryPlusGap() throws {
        let root = h(w(1), w(2))
        let result = compute(root, gaps: Gaps(inner: 10, outer: 0))
        let node = try #require(root.findWindow(2))

        let match = try #require(
            result.match(edge: 505, of: node, orientation: .horizontal, tolerance: 2))
        #expect(match.edgeOffset == 10)
        #expect(match.boundaryPosition(forEdge: 605) == 595, "間隔ぶん引いた位置が境界")
    }

    // 座標だけで探すと、引っ張ったのとは無関係なウィンドウが動く。
    @Test("同じ座標にある別の枝の境界は掴まない")
    func matchIgnoresBoundariesInOtherBranches() throws {
        let upper = h(w(1), w(2))
        let lower = h(w(3), w(4))
        let root = ContainerNode(orientation: .vertical, children: [upper, lower])
        let result = compute(root)

        // 上下どちらの H も x = 500 に境界を持つ。
        #expect(result.boundaries.filter { $0.position == 500 }.count == 2)

        let node = try #require(root.findWindow(3))
        let match = try #require(
            result.match(edge: 500, of: node, orientation: .horizontal, tolerance: 2))
        #expect(match.boundary.container === lower, "自分が属する側の境界を掴む")
    }

    // 深い位置のウィンドウの外側の辺は、何段か上の境界に対応する。
    @Test("祖先を遡って外側の境界にも当たる")
    func matchWalksUpToOuterBoundaries() throws {
        let deep = h(w(3), w(4))
        let root = ContainerNode(
            orientation: .horizontal,
            children: [w(1), ContainerNode(orientation: .vertical, children: [w(2), deep])])
        let result = compute(root, gaps: Gaps(inner: 10, outer: 0))

        // ルートの境界は 495。3 の左端はその奥側なので 505 にある。
        let node = try #require(root.findWindow(3))
        #expect(result.frames[3]?.minX == 505)

        let match = try #require(
            result.match(edge: 505, of: node, orientation: .horizontal, tolerance: 2))
        #expect(match.boundary.container === root, "2段上の境界を掴む")
        #expect(match.edgeOffset == 10)
        #expect(match.boundary.container !== deep)
    }

    @Test("どの境界にも当たらなければ照合は失敗する")
    func matchFailsWhenNoBoundaryIsNear() throws {
        let root = h(w(1), w(2))
        let result = compute(root)
        let node = try #require(root.findWindow(1))

        #expect(result.match(edge: 123, of: node, orientation: .horizontal, tolerance: 2) == nil)
        #expect(
            result.match(edge: 500, of: node, orientation: .vertical, tolerance: 2) == nil,
            "軸が違えば当たらない")
    }

    @Test("許容誤差の範囲なら一致とみなす")
    func matchToleratesSmallDifferences() throws {
        let root = h(w(1), w(2))
        let result = compute(root)
        let node = try #require(root.findWindow(1))

        #expect(result.match(edge: 501.5, of: node, orientation: .horizontal, tolerance: 2) != nil)
        #expect(result.match(edge: 503, of: node, orientation: .horizontal, tolerance: 2) == nil)
    }

    // MARK: - 最小寸法

    @Test("最小寸法に届かない子は下限で止まり、兄弟が譲る")
    func minimumsForceSiblingsToYield() {
        let result = compute(h(w(1), w(2)), minimums: [1: CGSize(width: 800, height: 0)])

        #expect(result.frames[1]?.width == 800)
        #expect(result.frames[2]?.width == 200, "兄弟が譲る")
    }

    @Test("下限を満たす子は比率どおりのまま")
    func satisfiedMinimumsDoNotDisturbWeights() {
        let result = compute(h(w(1), w(2)), minimums: [1: CGSize(width: 100, height: 100)])
        #expect(result.frames[1]?.width == 500)
        #expect(result.frames[2]?.width == 500)
    }

    // 片方だけ満たすと、割を食った側が一方的にはみ出して重なる。
    @Test("双方の下限を満たせない場合は下限に比例して分け合う")
    func unsatisfiableMinimumsSharedProportionally() throws {
        let result = compute(
            h(w(1), w(2)),
            minimums: [1: CGSize(width: 800, height: 0), 2: CGSize(width: 400, height: 0)])

        let first = try #require(result.frames[1])
        let second = try #require(result.frames[2])
        #expect(abs(first.width - 1000 * 800 / 1200) < 1, "\(first.width)")
        #expect(abs(second.width - 1000 * 400 / 1200) < 1, "\(second.width)")
        #expect(first.maxX == second.minX, "重なりも隙間も出ない")
    }

    @Test("下限は3枚以上でも順に効く")
    func minimumsCascadeAcrossManyChildren() {
        let result = compute(
            h(w(1), w(2), w(3)),
            minimums: [1: CGSize(width: 600, height: 0), 2: CGSize(width: 300, height: 0)])

        // 1 が 600 で固定 → 残り 400 を 2 と 3 が半分ずつ → 2 は 200 で下限割れ →
        // 2 も 300 で固定 → 3 が残りの 100 を取る。
        #expect(result.frames[1]?.width == 600)
        #expect(result.frames[2]?.width == 300)
        #expect(result.frames[3]?.width == 100)
    }

    @Test("入れ子の下限は分割軸に沿って合算され、直交軸では最大値になる")
    func nestedMinimumsAggregateByAxis() {
        // V[2, 3] の最小幅は max(300, 200) = 300、最小高さは 100 + 5 + 100 = 205。
        let gaps = Gaps(inner: 5, outer: 0)
        let root = h(w(1), v(w(2), w(3)))
        root.setWeights([0.95, 0.05])
        let result = compute(
            root, gaps: gaps,
            minimums: [
                2: CGSize(width: 300, height: 100),
                3: CGSize(width: 200, height: 100),
            ])

        #expect(result.frames[2]?.width == 300, "直交軸では最大値が効く")
        #expect(result.frames[3]?.width == 300)
        // 領域 1000 から間隔 5 と下限 300 を引いた残り。
        #expect(result.frames[1]?.width == CGFloat(695), "兄弟が譲る")
    }

    @Test("下限が指定されていないウィンドウは 0 として扱う")
    func unknownMinimumsAreZero() {
        let result = compute(h(w(1), w(2)), minimums: [:])
        #expect(result.frames[1]?.width == 500)
    }

    // MARK: - 領域が足りない場合

    // レイアウトは「潰れた矩形を返す」ところまでを担う。送るかどうかは Engine が決める
    // （寸法 0 を送りつけてもアプリは最小サイズに戻すだけで、結果は重なりになる）。
    @Test("枚数が多すぎても負の寸法は返さない")
    func neverReturnsNegativeSizes() {
        let root = ContainerNode(orientation: .horizontal)
        for id in CGWindowID(1)...CGWindowID(40) {
            root.append(w(id))
        }
        let result = compute(root, gaps: Gaps(inner: 20, outer: 5))

        for (id, rect) in result.frames {
            #expect(rect.width >= 0, "[\(id)] \(rect)")
            #expect(rect.height >= 0, "[\(id)] \(rect)")
        }
    }

    @Test("領域を使い切ったあとの子は領域の外へ出ない")
    func exhaustedAreaKeepsRectsInside() {
        let root = ContainerNode(orientation: .horizontal)
        for id in CGWindowID(1)...CGWindowID(40) {
            root.append(w(id))
        }
        let gaps = Gaps(inner: 40, outer: 5)
        let result = compute(root, gaps: gaps)
        let usable = gaps.usableArea(in: screen)

        for (id, rect) in result.frames {
            #expect(rect.minX >= usable.minX && rect.maxX <= usable.maxX, "[\(id)] \(rect)")
        }
    }
}

/// 最小寸法が収まらない状態の検出。
///
/// **macOS 固有の問題。** X11 のクライアントは WM の指定に従うが、macOS のアプリは
/// 指定より小さくならない（実測: Safari は幅 574、Parsec は 640 が下限）。合計が
/// 領域を超えると、どう配ってもウィンドウが隣にはみ出す。
///
/// 画面上はただ重なって見えるだけなので、**黙っていると「タイリングが壊れている」と
/// 読まれる。** 事実として持ち出して、打つ手を伝えられるようにする。
@Suite("収まらない配置の検出")
struct LayoutOverflowTests {

    private let area = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func compute(
        _ root: ContainerNode, minimums: [CGWindowID: CGSize]
    ) -> LayoutEngine.Result {
        LayoutEngine.compute(root: root, area: area, gaps: .zero, scale: 1, minimums: minimums)
    }

    @Test("収まるなら何も報告しない")
    func nothingIsReportedWhenItFits() {
        let root = ContainerNode(
            orientation: .horizontal, children: [WindowNode(1), WindowNode(2)])
        let result = compute(
            root, minimums: [1: CGSize(width: 300, height: 0), 2: CGSize(width: 300, height: 0)])
        #expect(result.overflows.isEmpty)
    }

    /// 実機で踏んだ形。Parsec 640 + ターミナル 381 + Safari 574 × 2 = 2169pt を
    /// 幅 1905pt に並べようとして、3か所で 70pt ずつ重なった。
    @Test("最小寸法の合計が領域を超えたら報告する")
    func anOverflowIsReported() throws {
        let root = ContainerNode(
            orientation: .horizontal,
            children: [WindowNode(1), WindowNode(2), WindowNode(3)])
        let result = compute(
            root,
            minimums: [
                1: CGSize(width: 640, height: 0),
                2: CGSize(width: 574, height: 0),
                3: CGSize(width: 574, height: 0),
            ])
        let overflow = try #require(result.overflows.first)
        #expect(overflow.axis == .horizontal)
        #expect(overflow.windowIDs == [1, 2, 3])
        #expect(overflow.required == 1788)
        #expect(overflow.available == 1000)
        #expect(overflow.shortfall == 788)
    }

    /// 直交する分割では領域を**共有する**ので、幅の下限は合計ではなく最大値。
    @Test("直交する分割は合計しない")
    func perpendicularSplitsShareTheirExtent() {
        let root = ContainerNode(
            orientation: .horizontal,
            children: [
                WindowNode(1),
                ContainerNode(orientation: .vertical, children: [WindowNode(2), WindowNode(3)]),
            ])
        // 縦に積んだ 2 と 3 は幅を共有するので、幅の下限は 400。合計 800 で収まる。
        let result = compute(
            root,
            minimums: [
                1: CGSize(width: 400, height: 0),
                2: CGSize(width: 400, height: 0),
                3: CGSize(width: 400, height: 0),
            ])
        #expect(result.overflows.isEmpty)
    }

    /// 入れ子の内側だけが収まらないこともある。**そのコンテナだけを報告する。**
    @Test("収まらない分割だけを報告する")
    func onlyTheOffendingSplitIsReported() throws {
        let inner = ContainerNode(
            orientation: .vertical, children: [WindowNode(2), WindowNode(3)])
        let root = ContainerNode(orientation: .horizontal, children: [WindowNode(1), inner])
        let result = compute(
            root,
            minimums: [
                1: CGSize(width: 400, height: 0),
                2: CGSize(width: 0, height: 600),
                3: CGSize(width: 0, height: 600),
            ])
        let overflow = try #require(result.overflows.first)
        #expect(result.overflows.count == 1)
        #expect(overflow.axis == .vertical)
        #expect(overflow.windowIDs == [2, 3])
    }

    /// 報告しても**配置そのものは止めない。** 重なってでも並べるほうが、
    /// 何も動かないより分かりやすい。
    @Test("報告しても矩形は出す")
    func framesAreStillProduced() {
        let root = ContainerNode(
            orientation: .horizontal, children: [WindowNode(1), WindowNode(2)])
        let result = compute(
            root, minimums: [1: CGSize(width: 900, height: 0), 2: CGSize(width: 900, height: 0)])
        #expect(!result.overflows.isEmpty)
        #expect(result.frames.count == 2)
        #expect(result.order == [1, 2])
    }
}
