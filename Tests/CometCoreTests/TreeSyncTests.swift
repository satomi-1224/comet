import CoreGraphics
import Testing

@testable import CometCore

/// 台帳（どのウィンドウがタイル対象か）とツリー（どう並んでいるか）を一致させる。
///
/// 追加も削除も最終的にここへ集まるので、どの経路で状態が変わっても
/// ツリーが台帳とずれない。
@Suite("TreeSync")
struct TreeSyncTests {

    private func h(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .horizontal, children: children)
    }

    private func v(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .vertical, children: children)
    }

    private func w(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    // MARK: - 追加

    @Test("空のツリーには渡された順に並ぶ")
    func emptyTreeGetsWindowsInOrder() {
        let root = ContainerNode(orientation: .horizontal)
        let change = TreeSync.reconcile(root: root, tiled: [5, 3, 9])

        #expect(root.windowIDs == [5, 3, 9])
        #expect(change.inserted == [5, 3, 9])
        #expect(change.removed.isEmpty)
    }

    @Test("既にある並びは変えない")
    func existingOrderIsPreserved() {
        let root = h(w(3), w(1), w(2))
        let change = TreeSync.reconcile(root: root, tiled: [1, 2, 3])

        #expect(root.windowIDs == [3, 1, 2], "台帳の並びで並べ替えたりしない")
        #expect(change.isEmpty)
    }

    @Test("新しいウィンドウはフォーカス中の隣に入る")
    func newWindowGoesNextToFocused() {
        let root = h(w(1), w(2), w(3))
        let change = TreeSync.reconcile(root: root, tiled: [1, 2, 3, 4], focused: 1)

        #expect(root.windowIDs == [1, 4, 2, 3])
        #expect(change.inserted == [4])
    }

    @Test("複数の新規はフォーカスの隣に順番どおり入る")
    func multipleNewWindowsKeepTheirOrder() {
        let root = h(w(1), w(2))
        TreeSync.reconcile(root: root, tiled: [1, 2, 3, 4], focused: 1)
        #expect(root.windowIDs == [1, 3, 4, 2])
    }

    @Test("フォーカスが分からなければ末尾に足す")
    func unknownFocusAppends() {
        let root = h(w(1), w(2))
        TreeSync.reconcile(root: root, tiled: [1, 2, 3], focused: nil)
        #expect(root.windowIDs == [1, 2, 3])

        TreeSync.reconcile(root: root, tiled: [1, 2, 3, 4], focused: 999)
        #expect(root.windowIDs == [1, 2, 3, 4], "木に無い ID がフォーカスでも末尾")
    }

    @Test("sibling では入れ子の中のフォーカスの隣に入る")
    func newWindowJoinsTheFocusedContainer() {
        let root = h(w(1), v(w(2), w(3)))
        TreeSync.reconcile(root: root, tiled: [1, 2, 3, 4], focused: 2, strategy: .sibling)
        #expect(root.description == "H[1, V[2, 4, 3]]")
    }

    // MARK: - 挿入の戦略

    // Phase 1 で実機検証した dwindle の形を、BSP ツリーの上で再現できること。
    @Test("split では枚数を増やすと dwindle の形になる")
    func splitStrategyReproducesDwindle() {
        let root = ContainerNode(orientation: .horizontal)
        var focused: CGWindowID?
        var tiled: [CGWindowID] = []
        var shapes: [String] = []

        for id in CGWindowID(1)...CGWindowID(5) {
            tiled.append(id)
            TreeSync.reconcile(root: root, tiled: tiled, focused: focused, strategy: .split)
            focused = id
            shapes.append(root.description)
        }

        #expect(
            shapes == [
                "H[1]",
                "H[1, 2]",
                "H[1, V[2, 3]]",
                "H[1, V[2, H[3, 4]]]",
                "H[1, V[2, H[3, V[4, 5]]]]",
            ], "\(shapes)")
    }

    @Test("sibling では枚数を増やすと1列に並ぶ")
    func siblingStrategyKeepsOneRow() {
        let root = ContainerNode(orientation: .horizontal)
        var focused: CGWindowID?
        var tiled: [CGWindowID] = []

        for id in CGWindowID(1)...CGWindowID(4) {
            tiled.append(id)
            TreeSync.reconcile(root: root, tiled: tiled, focused: focused, strategy: .sibling)
            focused = id
        }
        #expect(root.description == "H[1, 2, 3, 4]")
    }

    @Test("split で作るコンテナは親と逆向きになる")
    func splitCreatesOppositeOrientation() {
        let root = h(w(1), w(2))
        TreeSync.reconcile(root: root, tiled: [1, 2, 3], focused: 2, strategy: .split)

        let inner = root.children[1] as? ContainerNode
        #expect(inner?.orientation == .vertical, "\(root)")
        #expect(inner?.isOrientationExplicit == false, "自動で組んだものなので明示ではない")
    }

    @Test("split では包んでも領域の取り分は変わらない")
    func splitPreservesTheAnchorArea() {
        let root = h(w(1), w(2))
        root.setWeights([0.7, 0.3])
        TreeSync.reconcile(root: root, tiled: [1, 2, 3], focused: 2, strategy: .split)

        #expect(abs(root.weights[0] - 0.7) < 1e-9, "\(root.weights)")
        #expect(abs(root.weights[1] - 0.3) < 1e-9, "包まれた側の取り分もそのまま")
    }

    @Test("split でもルートが空なら最初の1枚はそのまま入る")
    func splitHandlesEmptyRoot() {
        let root = ContainerNode(orientation: .vertical)
        TreeSync.reconcile(root: root, tiled: [1], focused: nil, strategy: .split)
        #expect(root.description == "V[1]")
    }

    @Test("同じ ID を二度渡しても木には1つだけ入る")
    func duplicateIDsAreInsertedOnce() {
        let root = ContainerNode(orientation: .horizontal)
        TreeSync.reconcile(root: root, tiled: [1, 1, 2])
        #expect(root.windowIDs == [1, 2])
    }

    // MARK: - 削除

    @Test("対象から外れたウィンドウは木から消える")
    func untiledWindowsAreRemoved() {
        let root = h(w(1), w(2), w(3))
        let change = TreeSync.reconcile(root: root, tiled: [1, 3])

        #expect(root.windowIDs == [1, 3])
        #expect(change.removed == [2])
        #expect(change.inserted.isEmpty)
    }

    @Test("消えた結果できた単独コンテナは畳まれる")
    func emptiedContainersCollapse() {
        let root = h(w(1), v(w(2), w(3)))
        TreeSync.reconcile(root: root, tiled: [1, 2])
        #expect(root.description == "H[1, 2]")
    }

    @Test("全部消えるとルートだけが残る")
    func removingEverythingLeavesEmptyRoot() {
        let root = h(w(1), v(w(2), w(3)))
        let change = TreeSync.reconcile(root: root, tiled: [])

        #expect(root.isEmpty)
        #expect(Set(change.removed) == [1, 2, 3])
        #expect(root.invariantViolations().isEmpty)
    }

    // MARK: - 全体

    @Test("追加と削除が同時に起きても両方反映される")
    func insertsAndRemovalsCoexist() {
        let root = h(w(1), w(2))
        let change = TreeSync.reconcile(root: root, tiled: [1, 3], focused: 1)

        #expect(root.windowIDs == [1, 3])
        #expect(change.inserted == [3])
        #expect(change.removed == [2])
    }

    @Test("一致していれば変化なしと報告する")
    func reportsNoChangeWhenAlreadyInSync() {
        let root = h(w(1), v(w(2), w(3)))
        #expect(TreeSync.reconcile(root: root, tiled: [1, 2, 3]).isEmpty)
    }

    @Test("同じ入力で二度呼んでも形が変わらない")
    func reconcileIsIdempotent() {
        let root = h(w(1), v(w(2), w(3)))
        TreeSync.reconcile(root: root, tiled: [1, 2, 3, 4], focused: 3)
        let once = root.description

        TreeSync.reconcile(root: root, tiled: [1, 2, 3, 4], focused: 3)
        #expect(root.description == once)
    }

    @Test("整合のあとは不変条件をすべて満たす")
    func reconcileLeavesTreeConsistent() {
        let root = h(w(1), v(w(2), h(w(3), w(4))))
        TreeSync.reconcile(root: root, tiled: [2, 4, 5, 6], focused: 4)

        var violations: [String] = []
        collect(root, into: &violations)
        #expect(violations.isEmpty, "\(violations) / \(root)")
        #expect(Set(root.windowIDs) == [2, 4, 5, 6], "\(root)")
    }

    private func collect(_ node: Node, into result: inout [String]) {
        guard let container = node as? ContainerNode else { return }
        result.append(contentsOf: container.invariantViolations())
        for child in container.children {
            collect(child, into: &result)
        }
    }
}
