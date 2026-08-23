import CoreGraphics
import Testing
import CometCore

/// フローティングのウィンドウを狙うコマンドの綴りと計算。
///
/// **`Engine` の経路そのものは実機検証（`scripts/verify.sh`）で確かめる。**
/// ここで固定するのは、綴りが読めることと、動かす量の計算が合っていること。
@Suite("フローティングを狙う操作")
struct FloatingCommandTests {

    @Test("点数を付けた移動を解釈する（i3 の move left 40 px）")
    func parsesMoveWithPoints() throws {
        #expect(try Command.parse("move left 40 px") == .moveBy(.left, points: 40))
        #expect(try Command.parse("move down 10") == .moveBy(.down, points: 10))
        #expect(try Command.parse("move right 0 px") == .moveBy(.right, points: 0))
        // 点数が無ければ従来どおり列の中で入れ替わる。
        #expect(try Command.parse("move up") == .move(.up))
    }

    @Test("点数が読めなければ誤りとして扱う")
    func rejectsUnreadablePoints() {
        #expect(throws: Command.ParseError.self) { try Command.parse("move left much px") }
        #expect(throws: Command.ParseError.self) { try Command.parse("move sideways 10 px") }
    }

    @Test("中央へ寄せる指定を解釈する")
    func parsesMovePosition() throws {
        #expect(try Command.parse("move position center") == .movePosition(.center))
        #expect(throws: Command.ParseError.self) { try Command.parse("move position mouse") }
    }

    @Test("フローティングの切り替えを i3 の綴りで解釈する")
    func parsesFloatingToggle() throws {
        #expect(try Command.parse("floating toggle") == .floating(.toggle))
        #expect(try Command.parse("floating enable") == .floating(.on))
        #expect(try Command.parse("floating disable") == .floating(.off))
        #expect(throws: Command.ParseError.self) { try Command.parse("floating sideways") }
        #expect(throws: Command.ParseError.self) { try Command.parse("floating") }
    }

    @Test("トグルは今の状態から次を決める")
    func toggleResolves() {
        #expect(Toggle.toggle.resolve(current: true) == false)
        #expect(Toggle.toggle.resolve(current: false) == true)
        #expect(Toggle.on.resolve(current: true) == true)
        #expect(Toggle.off.resolve(current: false) == false)
    }

    // AX 座標系（Y は下向き）で符号を取り違えると、上を押して下へ動く。
    @Test("方向から動かす差分を求める")
    func directionOffsets() {
        #expect(Direction.left.offset(points: 10) == CGSize(width: -10, height: 0))
        #expect(Direction.right.offset(points: 10) == CGSize(width: 10, height: 0))
        #expect(Direction.up.offset(points: 10) == CGSize(width: 0, height: -10))
        #expect(Direction.down.offset(points: 10) == CGSize(width: 0, height: 10))
    }

    // 画面の外へ出せてしまうと、以後どのキーでも呼び戻せない。
    @Test("領域の外へ出た矩形は中へ押し込む")
    func clampsIntoArea() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let left = Geometry.clamped(CGRect(x: -50, y: 100, width: 200, height: 100), within: area)
        #expect(left == CGRect(x: 0, y: 100, width: 200, height: 100))

        let right = Geometry.clamped(CGRect(x: 950, y: 100, width: 200, height: 100), within: area)
        #expect(right == CGRect(x: 800, y: 100, width: 200, height: 100))

        let bottom = Geometry.clamped(CGRect(x: 10, y: 790, width: 100, height: 100), within: area)
        #expect(bottom == CGRect(x: 10, y: 700, width: 100, height: 100))

        let inside = CGRect(x: 10, y: 20, width: 100, height: 100)
        #expect(Geometry.clamped(inside, within: area) == inside, "中にあるものは動かさない")
    }

    @Test("領域より大きい矩形は左上を合わせるだけ")
    func clampsOversizedToOrigin() {
        let area = CGRect(x: 100, y: 50, width: 200, height: 200)
        let huge = CGRect(x: -500, y: -500, width: 1000, height: 1000)
        #expect(Geometry.clamped(huge, within: area) == CGRect(x: 100, y: 50, width: 1000, height: 1000))
    }
}

/// 間隔を後から変える（i3-gaps の `gaps`）。
@Suite("間隔の変更")
struct GapsCommandTests {

    @Test("i3-gaps の綴りを解釈する")
    func parsesI3Spelling() throws {
        #expect(
            try Command.parse("gaps inner all set 10")
                == .gaps(GapsChange(field: .inner, operation: .set, value: 10)))
        #expect(
            try Command.parse("gaps outer current plus 5")
                == .gaps(GapsChange(field: .outer, operation: .plus, value: 5)))
        // 範囲（current / all）は書かなくても通る。comet の間隔は全体で1つ。
        #expect(
            try Command.parse("gaps horizontal minus 3")
                == .gaps(GapsChange(field: .horizontal, operation: .minus, value: 3)))
    }

    @Test("読めない指定は誤りとして扱う")
    func rejectsUnknownArguments() {
        #expect(throws: Command.ParseError.self) { try Command.parse("gaps sideways set 10") }
        #expect(throws: Command.ParseError.self) { try Command.parse("gaps inner grow 10") }
        #expect(throws: Command.ParseError.self) { try Command.parse("gaps inner set wide") }
        #expect(throws: Command.ParseError.self) { try Command.parse("gaps inner set") }
    }

    @Test("inner は縦横の両方に効く")
    func innerAffectsBothAxes() {
        let gaps = Gaps(inner: 3, outer: 3)
        let changed = GapsChange(field: .inner, operation: .set, value: 12).applied(to: gaps)
        #expect(changed.innerHorizontal == 12)
        #expect(changed.innerVertical == 12)
        #expect(changed.outerTop == 3, "外周は変えない")
    }

    @Test("outer は四辺に効く")
    func outerAffectsAllEdges() {
        let changed = GapsChange(field: .outer, operation: .plus, value: 7)
            .applied(to: Gaps(inner: 3, outer: 3))
        #expect(changed.outerTop == 10)
        #expect(changed.outerBottom == 10)
        #expect(changed.outerLeft == 10)
        #expect(changed.outerRight == 10)
        #expect(changed.innerHorizontal == 3, "内側は変えない")
    }

    @Test("一辺だけを指定できる")
    func singleEdge() {
        let changed = GapsChange(field: .top, operation: .set, value: 40)
            .applied(to: Gaps(inner: 3, outer: 3))
        #expect(changed.outerTop == 40)
        #expect(changed.outerBottom == 3)
    }

    // 負の間隔は境界を領域の外へ押し出してウィンドウを重ねる。
    @Test("引きすぎても負にはならない")
    func neverGoesNegative() {
        let changed = GapsChange(field: .inner, operation: .minus, value: 100)
            .applied(to: Gaps(inner: 3, outer: 3))
        #expect(changed.innerHorizontal == 0)
        #expect(changed.innerVertical == 0)
    }
}

/// 層を直に指すフォーカス（i3 の `focus floating` / `focus tiling`）。
@Suite("層を選ぶフォーカス")
struct FocusLayerTests {

    @Test("i3 の綴りを解釈する")
    func parsesLayers() throws {
        #expect(try Command.parse("focus floating") == .focusLayer(.floating))
        #expect(try Command.parse("focus tiling") == .focusLayer(.tiling))
        #expect(try Command.parse("focus mode_toggle") == .focusLayer(.toggle))
        #expect(try Command.parse("focus mode-toggle") == .focusLayer(.toggle))
    }

    @Test("綴りに戻せる")
    func description() {
        #expect(Command.focusLayer(.toggle).description == "focus mode-toggle")
        #expect(Command.focusLayer(.floating).description == "focus floating")
        #expect(Command.focusLayer(.tiling).description == "focus tiling")
    }

    @Test("行き先の層が決まる")
    func wantsFloating() {
        #expect(FocusLayer.floating.wantsFloating == true)
        #expect(FocusLayer.tiling.wantsFloating == false)
        #expect(FocusLayer.toggle.wantsFloating == nil, "往復は今の状態から決める")
    }

    // `layout` の引数と取り違えないこと。`focus tiles` のような綴りは無い。
    @Test("知らない綴りは方向として読もうとして失敗する")
    func rejectsUnknownLayer() {
        #expect(throws: Command.ParseError.self) { try Command.parse("focus tiles") }
    }
}

/// 方向フォーカスが端で反対側へ回るか（i3 の `focus_wrapping`）。
@Suite("端での巻き戻し")
struct FocusWrappingTests {

    private func h(_ children: Node...) -> ContainerNode {
        let container = ContainerNode(orientation: .horizontal)
        children.forEach { container.append($0) }
        return container
    }
    private func v(_ children: Node...) -> ContainerNode {
        let container = ContainerNode(orientation: .vertical)
        children.forEach { container.append($0) }
        return container
    }
    private func w(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    @Test("既定では端で止まる")
    func stopsAtTheEdgeByDefault() throws {
        let root = h(w(1), w(2))
        let left = try #require(root.findWindow(1))
        #expect(TreeOperations.focusTarget(from: left, direction: .left) == nil)
    }

    @Test("有効なら反対の端へ回る")
    func wrapsWhenEnabled() throws {
        let root = h(w(1), w(2), w(3))
        let left = try #require(root.findWindow(1))
        let right = try #require(root.findWindow(3))
        #expect(
            TreeOperations.focusTarget(from: left, direction: .left, wrapping: true)?.windowID == 3)
        #expect(
            TreeOperations.focusTarget(from: right, direction: .right, wrapping: true)?.windowID
                == 1)
    }

    // 隣があるときは普通に隣へ行く。巻き戻しは端のときだけ。
    @Test("端でなければそのまま隣へ")
    func neighboursAreUnaffected() throws {
        let root = h(w(1), w(2))
        let left = try #require(root.findWindow(1))
        #expect(
            TreeOperations.focusTarget(from: left, direction: .right, wrapping: true)?.windowID == 2)
    }

    // ワークスペース全体で回すと、右端で right を押したとき左端まで飛んで面食らう。
    @Test("回るのは向きの合う一番内側のコンテナの中だけ")
    func wrapsInsideTheInnermostContainer() throws {
        // H[ 1, V[2, 3] ] — 2 から up を押すと V の中で 3 へ回る。
        let nested = v(w(2), w(3))
        _ = h(w(1), nested)
        let top = try #require(nested.findWindow(2))
        #expect(
            TreeOperations.focusTarget(from: top, direction: .up, wrapping: true)?.windowID == 3)
    }

    @Test("1枚しかなければ回らない")
    func aSingleChildDoesNotWrap() throws {
        let root = h(w(1))
        let only = try #require(root.findWindow(1))
        #expect(TreeOperations.focusTarget(from: only, direction: .left, wrapping: true) == nil)
    }
}
