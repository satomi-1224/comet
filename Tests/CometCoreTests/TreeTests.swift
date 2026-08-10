import CoreGraphics
import Testing

@testable import CometCore

/// BSP ツリーの構造操作。
///
/// ここが壊れるとレイアウト・コマンド・正規化のすべてが壊れる。
/// 検査の主眼は「操作のあとで不変条件が保たれているか」に置く。
@Suite("Tree")
struct TreeTests {

    private func window(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    private func container(_ orientation: Orientation, _ ids: CGWindowID...) -> ContainerNode {
        ContainerNode(orientation: orientation, children: ids.map(WindowNode.init))
    }

    private func expectWeights(
        _ node: ContainerNode, _ expected: [Double],
        _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(node.weights.count == expected.count, comment, sourceLocation: sourceLocation)
        guard node.weights.count == expected.count else { return }
        for (actual, want) in zip(node.weights, expected) {
            #expect(
                abs(actual - want) < 1e-9, "\(comment?.description ?? "") \(node.weights)",
                sourceLocation: sourceLocation)
        }
    }

    // MARK: - 不変条件

    @Test("生成直後のコンテナは不変条件を満たす")
    func freshContainerIsConsistent() {
        let root = container(.horizontal, 1, 2, 3)
        #expect(root.invariantViolations().isEmpty)
        expectWeights(root, [1.0 / 3, 1.0 / 3, 1.0 / 3], "均等に配られる")
    }

    @Test("子の parent は自分を指す")
    func childrenPointBack() {
        let root = container(.horizontal, 1, 2)
        for child in root.children {
            #expect(child.parent === root)
        }
    }

    @Test("空のコンテナは子も比率も持たない")
    func emptyContainer() {
        let root = ContainerNode(orientation: .horizontal)
        #expect(root.isEmpty)
        #expect(root.children.isEmpty)
        #expect(root.weights.isEmpty)
        #expect(root.invariantViolations().isEmpty, "空それ自体は不変条件違反ではない（ルートは空でも存在する）")
    }

    // MARK: - 追加

    @Test("追加すると新しい子が均等な取り分を得て、既存は比例して縮む")
    func insertTakesEqualShare() {
        let root = container(.horizontal, 1, 2)
        root.append(window(3))

        #expect(root.children.count == 3)
        expectWeights(root, [1.0 / 3, 1.0 / 3, 1.0 / 3])
        #expect(root.invariantViolations().isEmpty)
    }

    @Test("比率が偏っていても追加後の合計は 1 のまま")
    func insertKeepsSumWhenWeightsAreSkewed() {
        let root = container(.horizontal, 1, 2)
        root.setWeights([0.8, 0.2])
        root.append(window(3))

        expectWeights(root, [0.8 * 2 / 3, 0.2 * 2 / 3, 1.0 / 3], "既存の比は保たれる")
        #expect(abs(root.weights.reduce(0, +) - 1) < 1e-9)
    }

    @Test("位置を指定して挿入できる")
    func insertAtIndex() {
        let root = container(.horizontal, 1, 3)
        root.insert(window(2), at: 1)
        #expect(root.windowIDs == [1, 2, 3])
    }

    @Test("範囲外の添字への挿入は端に寄せる")
    func insertClampsIndex() {
        let root = container(.horizontal, 1, 2)
        root.insert(window(9), at: 99)
        #expect(root.windowIDs == [1, 2, 9])

        root.insert(window(0), at: -5)
        #expect(root.windowIDs == [0, 1, 2, 9])
    }

    // 同じノードが2つの親の children に入ると、レイアウトの再帰が同じ枝を
    // 二度たどって矩形が重なる。挿入時に古い親から必ず外す。
    @Test("別の親に挿入すると元の親から外れる")
    func insertDetachesFromPreviousParent() {
        let left = container(.horizontal, 1, 2)
        let right = ContainerNode(orientation: .vertical)
        let moved = left.children[0]

        right.append(moved)

        #expect(left.children.count == 1)
        #expect(left.windowIDs == [2])
        #expect(moved.parent === right)
        #expect(left.invariantViolations().isEmpty)
        #expect(right.invariantViolations().isEmpty)
    }

    // MARK: - 削除

    @Test("削除すると比率が残りへ比例配分される")
    func removeRedistributesWeight() {
        let root = container(.horizontal, 1, 2, 3)
        root.setWeights([0.5, 0.3, 0.2])
        root.remove(at: 1)

        #expect(root.windowIDs == [1, 3])
        expectWeights(root, [0.5 / 0.7, 0.2 / 0.7], "残りの比は保たれる")
    }

    @Test("削除したノードは親を失う")
    func removedNodeLosesParent() {
        let root = container(.horizontal, 1, 2)
        let removed = root.remove(at: 0)
        #expect(removed?.parent == nil)
    }

    @Test("ノードを指して削除できる")
    func removeByIdentity() {
        let root = container(.horizontal, 1, 2, 3)
        let target = root.children[1]
        #expect(root.remove(target) == 1)
        #expect(root.windowIDs == [1, 3])
        #expect(root.remove(target) == nil, "二度目は空振りする")
    }

    @Test("最後の子を削除すると空になる")
    func removeLastChild() {
        let root = container(.horizontal, 1)
        root.remove(at: 0)
        #expect(root.isEmpty)
        #expect(root.weights.isEmpty)
        #expect(root.invariantViolations().isEmpty)
    }

    @Test("範囲外の削除は無害")
    func removeOutOfRangeIsHarmless() {
        let root = container(.horizontal, 1, 2)
        #expect(root.remove(at: 5) == nil)
        #expect(root.remove(at: -1) == nil)
        #expect(root.windowIDs == [1, 2])
    }

    // MARK: - 入れ替えと差し替え

    // move コマンドは「窓が自分の寸法を持ったまま位置を交換する」意味にする。
    // 比率も一緒に入れ替えないと、移動した先の寸法に化けてしまう。
    @Test("入れ替えは比率も一緒に動く")
    func swapMovesWeightsToo() {
        let root = container(.horizontal, 1, 2)
        root.setWeights([0.7, 0.3])
        root.swapAt(0, 1)

        #expect(root.windowIDs == [2, 1])
        expectWeights(root, [0.3, 0.7])
    }

    // join-with は葉を新しいコンテナに包む。包んだあとの取り分は元の葉のもの。
    @Test("差し替えは比率と親子関係を引き継ぐ")
    func replaceInheritsWeightAndParent() {
        let root = container(.horizontal, 1, 2, 3)
        root.setWeights([0.5, 0.3, 0.2])

        let leaf = root.children[1]
        let wrapper = ContainerNode(orientation: .vertical)
        root.replace(at: 1, with: wrapper)
        wrapper.append(leaf)

        #expect(root.children[1] === wrapper)
        #expect(wrapper.parent === root)
        expectWeights(root, [0.5, 0.3, 0.2], "包んでも取り分は変わらない")
        #expect(leaf.parent === wrapper)
        #expect(root.invariantViolations().isEmpty)
    }

    // MARK: - 走査

    @Test("葉は深さ優先で左から並ぶ")
    func windowsAreOrderedDepthFirst() {
        let nested = container(.vertical, 2, 3)
        let root = ContainerNode(orientation: .horizontal, children: [WindowNode(1), nested])
        root.append(WindowNode(4))

        #expect(root.windowIDs == [1, 2, 3, 4])
    }

    @Test("ID からウィンドウノードを引ける")
    func findWindowByID() {
        let nested = container(.vertical, 2, 3)
        let root = ContainerNode(orientation: .horizontal, children: [WindowNode(1), nested])

        #expect(root.findWindow(3) === nested.children[1])
        #expect(root.findWindow(99) == nil)
    }

    @Test("祖先は近い順に並ぶ")
    func ancestorsAreOrderedFromNearest() {
        let inner = container(.vertical, 2)
        let middle = ContainerNode(orientation: .horizontal, children: [inner])
        let root = ContainerNode(orientation: .vertical, children: [middle])

        let leaf = inner.children[0]
        #expect(leaf.ancestors.count == 3)
        #expect(leaf.ancestors[0] === inner)
        #expect(leaf.ancestors[1] === middle)
        #expect(leaf.ancestors[2] === root)
    }

    @Test("深い入れ子でも葉をすべて数え上げる")
    func deeplyNestedWindowsAreAllFound() {
        let root = ContainerNode(orientation: .horizontal)
        var cursor = root
        for id in CGWindowID(1)...CGWindowID(10) {
            cursor.append(WindowNode(id))
            let next = ContainerNode(orientation: cursor.orientation.flipped)
            cursor.append(next)
            cursor = next
        }
        #expect(root.windowIDs == Array(CGWindowID(1)...CGWindowID(10)))
    }

    // MARK: - 向き

    @Test("向きの反転は対合")
    func flippedIsInvolution() {
        #expect(Orientation.horizontal.flipped == .vertical)
        #expect(Orientation.vertical.flipped == .horizontal)
        #expect(Orientation.horizontal.flipped.flipped == .horizontal)
    }

    // MARK: - 不変条件の検査そのもの

    // 検査が「常に空」を返すだけの飾りだと、後続の修正で壊れても気づけない。
    @Test("不変条件の検査は破れを見つける")
    func invariantCheckDetectsBreakage() {
        let root = container(.horizontal, 1, 2)
        root.breakWeightsForTesting([0.5, 0.9])
        #expect(!root.invariantViolations().isEmpty, "合計が 1 でない")

        let mismatched = container(.horizontal, 1, 2)
        mismatched.breakWeightsForTesting([1.0])
        #expect(!mismatched.invariantViolations().isEmpty, "要素数が合わない")
    }
}
