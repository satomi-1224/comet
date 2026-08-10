import CoreGraphics
import Testing

@testable import CometCore

/// 正規化。木を変更するすべてのコマンドの直後、レイアウト計算の直前に走る。
///
/// 木の形は `H[1, V[2, 3]]` の記法で書く（H = horizontal、V = vertical、数字はウィンドウ ID）。
@Suite("Normalization")
struct NormalizationTests {

    private func h(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .horizontal, children: children)
    }

    private func v(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .vertical, children: children)
    }

    private func w(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    // MARK: - 空コンテナ（設定に関わらず常に除去する）

    @Test("空のコンテナは親から除かれる")
    func emptyContainerIsRemoved() {
        let root = h(w(1), h(), w(2))
        Normalization.normalize(root)
        #expect(root.description == "H[1, 2]")
        #expect(root.invariantViolations().isEmpty)
    }

    @Test("空になった枝は根元まで畳まれる")
    func emptyBranchCollapsesUpward() {
        let root = h(w(1), v(h(v())))
        Normalization.normalize(root)
        #expect(root.description == "H[1]")
    }

    @Test("ルートが空でも消さない")
    func emptyRootSurvives() {
        let root = ContainerNode(orientation: .horizontal)
        Normalization.normalize(root)
        #expect(root.isEmpty)
        #expect(root.description == "H[]")
    }

    @Test("正規化を切っても空コンテナは除かれる")
    func emptyContainerIsRemovedEvenWhenDisabled() {
        let root = h(w(1), v(), w(2))
        Normalization.normalize(root, config: .off)
        #expect(root.description == "H[1, 2]")
    }

    // MARK: - flatten-containers

    @Test("子が1つのコンテナは潰れて子が昇格する")
    func singleChildContainerIsFlattened() {
        let root = h(w(1), v(w(2)), w(3))
        Normalization.normalize(root)
        #expect(root.description == "H[1, 2, 3]")
        #expect(root.invariantViolations().isEmpty)
    }

    @Test("潰れたコンテナの取り分は昇格した子が引き継ぐ")
    func flattenInheritsWeight() {
        let root = h(w(1), v(w(2)), w(3))
        root.setWeights([0.2, 0.5, 0.3])
        Normalization.normalize(root)

        #expect(root.description == "H[1, 2, 3]")
        #expect(abs(root.weights[1] - 0.5) < 1e-9, "\(root.weights)")
    }

    @Test("ルートの唯一の子がコンテナならルートが吸収する")
    func rootAbsorbsSingleContainerChild() {
        let root = h(v(w(1), w(2)))
        Normalization.normalize(root)

        #expect(root.description == "V[1, 2]", "向きも引き継ぐ")
        #expect(root.children.count == 2)
        #expect(root.invariantViolations().isEmpty)
    }

    @Test("何段でも一度の呼び出しで解決する")
    func nestedSingleChildChainsCollapseInOnePass() {
        let root = h(v(h(v(w(1), w(2)))))
        Normalization.normalize(root)
        #expect(root.description == "V[1, 2]")
    }

    @Test("ルートの唯一の子がウィンドウなら何もしない")
    func rootWithSingleWindowIsLeftAlone() {
        let root = h(w(1))
        Normalization.normalize(root)
        #expect(root.description == "H[1]")
    }

    @Test("設定を切れば潰さない")
    func flattenCanBeDisabled() {
        let root = h(w(1), v(w(2)))
        Normalization.normalize(root, config: NormalizationConfig(flattenContainers: false, oppositeOrientationForNested: false))
        #expect(root.description == "H[1, V[2]]")
    }

    // MARK: - opposite-orientation-for-nested

    @Test("入れ子コンテナは親と逆向きになる")
    func nestedContainerGetsOppositeOrientation() {
        let root = h(w(1), h(w(2), w(3)))
        Normalization.normalize(root)
        #expect(root.description == "H[1, V[2, 3]]")
    }

    @Test("すでに逆向きなら触らない")
    func oppositeOrientationIsLeftAlone() {
        let root = h(w(1), v(w(2), w(3)))
        Normalization.normalize(root)
        #expect(root.description == "H[1, V[2, 3]]")
    }

    @Test("向きの修正は上から下へ伝播する")
    func orientationFixPropagatesDownward() {
        // 3段すべて horizontal。上から順に決めないと、親を直した結果で
        // 子の判定が変わることを取りこぼす。
        let root = h(w(1), h(w(2), h(w(3), w(4))))
        Normalization.normalize(root)
        #expect(root.description == "H[1, V[2, H[3, 4]]]")
    }

    @Test("設定を切れば向きを変えない")
    func oppositeOrientationCanBeDisabled() {
        let root = h(w(1), h(w(2), w(3)))
        Normalization.normalize(
            root, config: NormalizationConfig(flattenContainers: true, oppositeOrientationForNested: false))
        #expect(root.description == "H[1, H[2, 3]]")
    }

    // MARK: - 比率

    @Test("比率の合計は常に 1 に直る")
    func weightsAlwaysSumToOne() {
        let root = h(w(1), w(2), w(3))
        root.breakWeightsForTesting([2, 3, 5])
        Normalization.normalize(root)

        #expect(abs(root.weights.reduce(0, +) - 1) < 1e-9, "\(root.weights)")
        #expect(abs(root.weights[0] - 0.2) < 1e-9, "比は保たれる")
    }

    @Test("合計が 0 なら均等に配り直す")
    func zeroWeightsBecomeEqual() {
        let root = h(w(1), w(2), w(3), w(4))
        root.breakWeightsForTesting([0, 0, 0, 0])
        Normalization.normalize(root)
        #expect(root.weights.allSatisfy { abs($0 - 0.25) < 1e-9 }, "\(root.weights)")
    }

    @Test("負の比率は均等へ落とす")
    func negativeWeightsBecomeEqual() {
        let root = h(w(1), w(2))
        root.breakWeightsForTesting([-1, 2])
        Normalization.normalize(root)
        #expect(root.weights.allSatisfy { $0 > 0 }, "\(root.weights)")
        #expect(abs(root.weights.reduce(0, +) - 1) < 1e-9)
    }

    @Test("要素数がずれていても直る")
    func weightCountIsRepaired() {
        let root = h(w(1), w(2), w(3))
        root.breakWeightsForTesting([0.5])
        Normalization.normalize(root)
        #expect(root.weights.count == 3)
        #expect(root.invariantViolations().isEmpty)
    }

    // MARK: - 全体

    @Test("正規化のあとは不変条件をすべて満たす")
    func normalizationRestoresAllInvariants() {
        let root = h(w(1), h(v(w(2)), h(), w(3)), v(w(4), h(w(5), w(6))))
        Normalization.normalize(root)

        var violations: [String] = []
        collectViolations(root, into: &violations)
        #expect(violations.isEmpty, "\(violations) / \(root)")
    }

    @Test("二度目の正規化は何も変えない")
    func normalizationIsIdempotent() {
        let root = h(w(1), h(v(w(2)), h(), w(3)), v(w(4), h(w(5), w(6))))
        Normalization.normalize(root)
        let once = root.description
        let weightsOnce = root.weights

        Normalization.normalize(root)
        #expect(root.description == once)
        #expect(root.weights == weightsOnce)
    }

    @Test("正規化はウィンドウを1枚も失わない")
    func normalizationPreservesAllWindows() {
        let root = h(w(1), h(v(w(2)), h(), w(3)), v(w(4), h(w(5), w(6))))
        let before = Set(root.windowIDs)
        Normalization.normalize(root)
        #expect(Set(root.windowIDs) == before)
        #expect(root.windowIDs.count == 6, "重複もしない")
    }

    private func collectViolations(_ node: Node, into result: inout [String]) {
        guard let container = node as? ContainerNode else { return }
        result.append(contentsOf: container.invariantViolations())
        for child in container.children {
            collectViolations(child, into: &result)
        }
    }
}
