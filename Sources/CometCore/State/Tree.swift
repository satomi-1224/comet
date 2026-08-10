import CoreGraphics

/// BSP ツリーのノード。**葉がウィンドウ、内部ノードがコンテナ。**
///
/// 参照型なのは親への弱参照を持つため。木は `Engine`（メインアクター）の中だけで
/// 触られるので `Sendable` にはしない。矩形など値だけが並行境界を越える。
///
/// ## 不変条件
///
/// すべての木操作のあとで以下が保たれること。破れを検出するには
/// ``ContainerNode/invariantViolations()`` を使う。
///
/// 1. `children.count == weights.count`
/// 2. `weights` はすべて正で、合計が 1（誤差 1e-9 以内）
/// 3. すべての子の `parent` が自分を指している
/// 4. 空のコンテナは存在しない（ルートを除く）
///
/// 4 は木を変更するコマンドの直後に ``Normalization`` が回復させる。
/// 1〜3 は個々の操作が常に保つ。
public class Node: CustomStringConvertible {

    /// 親コンテナ。ルートのみ `nil`。
    public internal(set) weak var parent: ContainerNode?

    init() {}

    public var description: String { "?" }
}

/// 葉。ウィンドウ1枚に対応する。
public final class WindowNode: Node {

    public let windowID: CGWindowID

    /// 最後にフォーカスされた時刻（`mach_absolute_time` 相当の単調増加値）。
    ///
    /// 方向フォーカスでコンテナへ降りるとき、どの葉を選ぶかの決め手になる。
    public var lastFocusedAt: UInt64 = 0

    public init(_ windowID: CGWindowID) {
        self.windowID = windowID
        super.init()
    }

    public override var description: String { "\(windowID)" }
}

/// 内部ノード。子を一方向に並べる。
public final class ContainerNode: Node {

    public var orientation: Orientation

    /// 利用者が `layout` コマンドで向きを選んだか。
    ///
    /// 正規化の「入れ子は親と逆向き」は**自動で組まれた形を整えるための規則**なので、
    /// 手で選んだ向きには適用しない。適用すると設定したそばから戻され、
    /// キーが効いていないように見える。
    public internal(set) var isOrientationExplicit = false

    public private(set) var children: [Node] = []

    /// 各子の占有比率。合計 1。`children` と同じ長さを常に保つ。
    public private(set) var weights: [Double] = []

    public init(orientation: Orientation, children: [Node] = []) {
        self.orientation = orientation
        super.init()
        for child in children {
            append(child)
        }
    }

    public override var description: String {
        "\(orientation.symbol)[\(children.map(\.description).joined(separator: ", "))]"
    }

    // MARK: - 参照

    public var isEmpty: Bool { children.isEmpty }

    /// 同一性（`===`）で探す。同じウィンドウ ID のノードが複数ありうるため、
    /// 値の一致では引かない。
    public func index(of node: Node) -> Int? {
        children.firstIndex { $0 === node }
    }

    // MARK: - 変更

    public func append(_ node: Node) {
        insert(node, at: children.count)
    }

    /// 挿入する。新しい子は均等な取り分（`1/(n+1)`）を得て、既存の子は比を保ったまま縮む。
    ///
    /// - すでに**別の**親を持つノードは、その親から外してから挿入する。同じノードが
    ///   2つの親の `children` に入ると、レイアウトの再帰が同じ枝を二度たどって矩形が重なる。
    /// - すでに**自分の**子であるノードは並べ替えとして扱い、取り分を保つ。
    ///   `index` は抜く前の並びに対する位置として解釈する。
    /// - 範囲外の `index` は端に寄せる。
    public func insert(_ node: Node, at index: Int) {
        if let existing = self.index(of: node) {
            ensureWeightCount()
            let weight = weights[existing]
            children.remove(at: existing)
            weights.remove(at: existing)
            // 自分を抜いた分だけ、後ろの位置は前へずれる。
            let position = clamped(index > existing ? index - 1 : index)
            children.insert(node, at: position)
            weights.insert(weight, at: position)
            repairWeights()
            return
        }

        node.parent?.remove(node)

        let position = clamped(index)
        let share = 1 / Double(children.count + 1)
        for i in weights.indices {
            weights[i] *= 1 - share
        }
        children.insert(node, at: position)
        weights.insert(share, at: position)
        node.parent = self
        repairWeights()
    }

    /// 取り除く。空いた取り分は残りへ比例配分される。
    @discardableResult
    public func remove(at index: Int) -> Node? {
        guard children.indices.contains(index) else { return nil }
        ensureWeightCount()
        let node = children.remove(at: index)
        weights.remove(at: index)
        node.parent = nil
        repairWeights()
        return node
    }

    /// - Returns: 取り除いた位置。子でなければ `nil`。
    @discardableResult
    public func remove(_ node: Node) -> Int? {
        guard let index = index(of: node) else { return nil }
        remove(at: index)
        return index
    }

    /// 子を差し替える。**取り分と位置は引き継がれる。**
    ///
    /// `join-with` で葉を新しいコンテナに包むときに使う。包んでも領域は変わらない。
    /// 自分の子を自分の子で置き換えることはできない（呼び出し側の誤りなので何もしない）。
    @discardableResult
    public func replace(at index: Int, with node: Node) -> Node? {
        guard children.indices.contains(index), node.parent !== self else { return nil }
        node.parent?.remove(node)

        let old = children[index]
        old.parent = nil
        children[index] = node
        node.parent = self
        return old
    }

    /// 位置を入れ替える。**取り分も一緒に動く。**
    ///
    /// `move` は「ウィンドウが自分の寸法を持ったまま位置を交換する」意味にする。
    /// 比率を置いていくと、移動した先の寸法に化けて驚く。
    public func swapAt(_ i: Int, _ j: Int) {
        guard children.indices.contains(i), children.indices.contains(j) else { return }
        ensureWeightCount()
        children.swapAt(i, j)
        weights.swapAt(i, j)
    }

    /// 比率をまとめて設定する。合計 1 に直してから入る。要素数が合わなければ何もしない。
    public func setWeights(_ values: [Double]) {
        guard values.count == children.count else { return }
        weights = values
        repairWeights()
    }

    /// 子 `leading` とその次の子の**境界を動かす**。両者の取り分の合計は変わらない。
    ///
    /// 手動リサイズと `resize` コマンドはどちらもここへ集まる。
    ///
    /// - Parameter minimumWeight: これ以下には縮めない。潰れ防止。
    /// - Returns: 実際に動かせた量。上限に当たると要求より小さくなる。
    @discardableResult
    public func moveBoundary(after leading: Int, by delta: Double, minimumWeight: Double = 0.05)
        -> Double
    {
        let trailing = leading + 1
        guard children.indices.contains(leading), children.indices.contains(trailing) else {
            return 0
        }
        ensureWeightCount()

        let pair = weights[leading] + weights[trailing]
        // 2枚ぶんの取り分が下限2つを満たせないなら動かす余地がない。
        let lower = min(minimumWeight, pair / 2)
        let applied = min(max(delta, lower - weights[leading]), pair - lower - weights[leading])
        guard applied != 0 else { return 0 }

        weights[leading] += applied
        weights[trailing] -= applied
        return applied
    }

    // MARK: - 不変条件

    /// 不変条件の破れを列挙する。返り値が空なら健全。
    ///
    /// 自分と直接の子だけを見る。木全体を調べるには各コンテナで呼ぶこと。
    public func invariantViolations() -> [String] {
        var result: [String] = []

        if children.count != weights.count {
            result.append("子 \(children.count) 個に対して比率が \(weights.count) 個")
        }

        if !children.isEmpty && children.count == weights.count {
            let sum = weights.reduce(0, +)
            if abs(sum - 1) > 1e-9 {
                result.append("比率の合計が \(sum)")
            }
            if let bad = weights.first(where: { !($0 > 0) || !$0.isFinite }) {
                result.append("比率に \(bad) がある")
            }
        }

        for (index, child) in children.enumerated() {
            if child.parent !== self {
                result.append("子 \(index) の親が自分を指していない")
            }
            if let container = child as? ContainerNode, container.isEmpty {
                result.append("子 \(index) が空のコンテナ")
            }
        }
        return result
    }

    /// 比率の要素数が子と揃っていることを確かめ、崩れていれば直す。
    ///
    /// 不変条件で保証されているので通常は空振りする。それでも添字を触る前に
    /// 挟んでおくのは、**常駐プロセスが添字外参照で落ちるより、均等に配り直して
    /// 動き続けるほうが害が小さい**ため。
    private func ensureWeightCount() {
        guard weights.count != children.count else { return }
        repairWeights()
    }

    /// 比率を「要素数が `children` と一致し、すべて正で、合計が 1」の状態へ直す。
    ///
    /// 比の情報が信用できない場合（数が合わない・非正の値がある・合計が 0）は
    /// 推し量る根拠がないので均等に配り直す。
    func repairWeights() {
        guard !children.isEmpty else {
            weights = []
            return
        }

        let sum = weights.reduce(0, +)
        guard weights.count == children.count,
            sum > 0, sum.isFinite,
            weights.allSatisfy({ $0 > 0 && $0.isFinite })
        else {
            weights = Array(repeating: 1 / Double(children.count), count: children.count)
            return
        }
        guard abs(sum - 1) > 1e-12 else { return }
        weights = weights.map { $0 / sum }
    }

    /// 隣り合う2つの子を、空のコンテナに包む。
    ///
    /// **元の2つが占めていた領域を新しいコンテナが引き継ぎ、他の子の取り分は変わらない。**
    /// 包まれた2つは新しいコンテナの中で元の比を保つ。並び順は元のまま
    /// （添字の小さいほうが手前）なので、幾何的な前後が入れ替わらない。
    @discardableResult
    func wrapChildren(at first: Int, and second: Int, into container: ContainerNode) -> Bool {
        guard first != second,
            children.indices.contains(first), children.indices.contains(second),
            container.isEmpty, container !== self, container.parent == nil
        else { return false }
        ensureWeightCount()

        let low = min(first, second)
        let high = max(first, second)
        let lowWeight = weights[low]
        let highWeight = weights[high]
        let leading = children[low]
        let trailing = children[high]

        // 添字の大きいほうから外さないと、残った添字がずれる。
        children.remove(at: high)
        weights.remove(at: high)
        children.remove(at: low)
        weights.remove(at: low)
        leading.parent = nil
        trailing.parent = nil

        container.append(leading)
        container.append(trailing)
        container.setWeights([lowWeight, highWeight])

        children.insert(container, at: low)
        weights.insert(lowWeight + highWeight, at: low)
        container.parent = self
        repairWeights()
        return true
    }

    /// 唯一の子であるコンテナを自分に取り込む。向き・子・取り分をそのまま引き継ぐ。
    ///
    /// ルートは消せないので、ルートの唯一の子がコンテナのときの flatten はこの形になる。
    /// 向きも引き継がないと、上下に並んでいたものが左右に化ける。
    ///
    /// - Returns: 取り込めたか。呼び出し側が「進んだかどうか」で
    ///   ループを止められるよう、空振りを区別できるようにしてある。
    @discardableResult
    func absorb(_ child: ContainerNode) -> Bool {
        guard children.count == 1, children[0] === child else { return false }

        orientation = child.orientation
        isOrientationExplicit = child.isOrientationExplicit
        children = child.children
        weights = child.weights
        for node in children {
            node.parent = self
        }
        // 捨てるコンテナに子を持たせたままにしない。親を指さない子を数えるような
        // 診断が誤作動する。
        child.children = []
        child.weights = []
        child.parent = nil
        repairWeights()
        return true
    }

    /// 不変条件の検査そのものを試すための抜け道。**テスト専用。**
    func breakWeightsForTesting(_ values: [Double]) {
        weights = values
    }

    private func clamped(_ index: Int) -> Int {
        min(max(index, 0), children.count)
    }
}

// MARK: - 走査

extension Node {

    /// 根まで遡る。
    public var root: Node {
        var node: Node = self
        while let parent = node.parent {
            node = parent
        }
        return node
    }

    /// 祖先を近い順に並べる。
    public var ancestors: [ContainerNode] {
        var result: [ContainerNode] = []
        var cursor = parent
        while let node = cursor {
            result.append(node)
            cursor = node.parent
        }
        return result
    }

    /// 葉を深さ優先・左から順に並べる。レイアウトの適用順もこれに従う。
    public var windowNodes: [WindowNode] {
        var result: [WindowNode] = []
        collectWindowNodes(into: &result)
        return result
    }

    public var windowIDs: [CGWindowID] {
        windowNodes.map(\.windowID)
    }

    public func findWindow(_ id: CGWindowID) -> WindowNode? {
        if let window = self as? WindowNode {
            return window.windowID == id ? window : nil
        }
        guard let container = self as? ContainerNode else { return nil }
        for child in container.children {
            if let found = child.findWindow(id) { return found }
        }
        return nil
    }

    private func collectWindowNodes(into result: inout [WindowNode]) {
        if let window = self as? WindowNode {
            result.append(window)
            return
        }
        guard let container = self as? ContainerNode else { return }
        for child in container.children {
            child.collectWindowNodes(into: &result)
        }
    }
}
