import CoreGraphics

/// ツリーに対する操作。**副作用はツリーの中だけに閉じる。**
///
/// AX には触らない。正規化 → レイアウト → `FrameScheduler` の流し込みは呼び出し側が行う。
/// ここが**メモリ操作だけで終わる**ことが症状B（リサイズ連打で追従しない）の対策の要点で、
/// 連打しても AX の往復は増えず、最後の状態だけがコアレスされて適用される。
public enum TreeOperations {

    // MARK: - focus

    /// 方向フォーカスの行き先。木は変えない。
    ///
    /// 自分の親から順に、向きが一致する祖先を探して隣を見る。見つからなければ `nil`。
    ///
    /// - Parameters:
    ///   - node: 起点。`focus parent` でコンテナを選んでいるときはコンテナが来る
    ///     （i3 と同じく、そこから隣へ出る）。行き先は必ず葉。
    ///   - wrapping: 端まで来たら反対の端へ回るか（i3 の `focus_wrapping`）。
    ///     **回るのは向きの合う一番内側のコンテナの中だけ。** ワークスペース全体で
    ///     回すと、右端で `right` を押したときに左端まで飛んで面食らう。
    public static func focusTarget(
        from node: Node, direction: Direction, wrapping: Bool = false
    ) -> WindowNode? {
        var current: Node = node
        /// 端に当たった一番内側のコンテナ。巻き戻す先を決めるために覚えておく。
        var innermostEdge: (container: ContainerNode, index: Int)?
        while let parent = current.parent {
            if parent.orientation == direction.orientation, let index = parent.index(of: current) {
                let next = direction.isForward ? index + 1 : index - 1
                if parent.children.indices.contains(next) {
                    return descendToLeaf(parent.children[next])
                }
                if innermostEdge == nil, parent.children.count > 1 {
                    innermostEdge = (parent, index)
                }
            }
            current = parent
        }
        guard wrapping, let edge = innermostEdge else { return nil }
        // 端に居るので反対の端へ回る。
        let wrapped = direction.isForward ? 0 : edge.container.children.count - 1
        guard wrapped != edge.index else { return nil }
        return descendToLeaf(edge.container.children[wrapped])
    }

    /// コンテナへ降りるときの行き先。**最後にフォーカスした葉**を選ぶ。
    ///
    /// 同点なら深さ優先で最初の葉。起動直後（全て 0）でも行き先が揺れない。
    public static func descendToLeaf(_ node: Node) -> WindowNode? {
        let leaves = node.windowNodes
        guard var best = leaves.first else { return nil }
        for leaf in leaves.dropFirst() where leaf.lastFocusedAt > best.lastFocusedAt {
            best = leaf
        }
        return best
    }

    // MARK: - move

    /// ウィンドウを方向へ動かす。
    ///
    /// 向きが一致する祖先を親方向に探し、そこで次のいずれかを行う。
    ///
    /// | 状況 | 動き |
    /// |---|---|
    /// | 自分の親の中で、隣がウィンドウ | 位置を入れ替える（寸法は持ったまま） |
    /// | 自分の親の中で、隣がコンテナ | そのコンテナの近い端へ入る |
    /// | 何段か上のコンテナ | 入れ子から抜けて、通ってきたコンテナの隣へ出る |
    ///
    /// - Parameter node: 動かす対象。`focus parent` でコンテナを選んでいるときは
    ///   **コンテナごと**動く（i3 と同じ）。
    /// - Returns: 木が変わったか。向きが一致する祖先が無ければ `false`。
    @discardableResult
    public static func move(_ node: Node, direction: Direction) -> Bool {
        var current: Node = node
        while let parent = current.parent {
            guard parent.orientation == direction.orientation,
                let index = parent.index(of: current)
            else {
                current = parent
                continue
            }

            let next = direction.isForward ? index + 1 : index - 1

            if current !== node {
                // 入れ子から抜ける。抜けた先にコンテナがあるならその中へ入り、
                // 無ければ通ってきたコンテナの隣に出る。端でも外側へは出られるので、
                // 隣の有無で行けるかどうかは決まらない。
                if parent.children.indices.contains(next),
                    let container = parent.children[next] as? ContainerNode
                {
                    container.insert(node, at: direction.isForward ? 0 : container.children.count)
                } else {
                    parent.insert(node, at: direction.isForward ? index + 1 : index)
                }
                return true
            }

            guard parent.children.indices.contains(next) else {
                // 自分の親の端。もう一段上に出口があるかもしれない。
                current = parent
                continue
            }

            if let container = parent.children[next] as? ContainerNode {
                parent.remove(node)
                container.insert(node, at: direction.isForward ? 0 : container.children.count)
            } else {
                parent.swapAt(index, next)
            }
            return true
        }
        return false
    }

    // MARK: - resize

    /// 分割の境界を動かして、ウィンドウの寸法を変える。
    ///
    /// **ウィンドウ単体のサイズを直接変えることはできない**。
    /// 変えるのは常に境界なので、兄弟が同量を譲り、間隔は設定値どおりに保たれる。
    ///
    /// - Parameters:
    ///   - layout: 直近のレイアウト。点数を比率へ直すために、そのコンテナが
    ///     配分できる長さを引く。
    /// - Returns: 比率が変わったか。下限に当たって動かせなければ `false`。
    @discardableResult
    public static func resize(
        _ node: Node,
        dimension: Dimension,
        delta: CGFloat,
        layout: LayoutEngine.Result,
        minimumWeight: Double = 0.05
    ) -> Bool {
        var current: Node = node
        while let parent = current.parent {
            guard parent.orientation == dimension.orientation,
                let index = parent.index(of: current)
            else {
                current = parent
                continue
            }

            guard let available = layout.availableLength(of: parent), available > 0 else {
                return false
            }
            let deltaWeight = Double(delta / available)

            // 次の子との境界を動かす。自分が最後なら手前の境界を逆向きに動かす
            // （どちらでも「自分が delta ぶん増える」意味になる）。
            if parent.children.indices.contains(index + 1) {
                return parent.moveBoundary(
                    after: index, by: deltaWeight, minimumWeight: minimumWeight) != 0
            }
            if index > 0 {
                return parent.moveBoundary(
                    after: index - 1, by: -deltaWeight, minimumWeight: minimumWeight) != 0
            }
            return false
        }
        return false
    }

    /// 境界を絶対位置へ動かす。手動リサイズの受け口。
    ///
    /// - Important: **必ず「今の比率を反映した境界」を渡すこと。**
    ///   ドラッグ中は同じ辺について通知が何度も届く。適用前の座標を基準にすると
    ///   同じ量を繰り返し足してしまい、追従が暴走する（実機で踏んだ失敗）。
    ///   どの境界かを見分けるのに古いレイアウトを使うのは構わないが、
    ///   移動量を求める基準は ``LayoutEngine/Result/boundary(like:)`` で引き直す。
    ///
    /// - Returns: 比率が変わったか。下限に当たって動かせなければ `false`。
    @discardableResult
    public static func moveBoundary(
        _ boundary: SplitBoundary,
        to position: CGFloat,
        minimumWeight: Double = 0.05
    ) -> Bool {
        guard let delta = boundary.weightDelta(movingTo: position) else { return false }
        return boundary.container.moveBoundary(
            after: boundary.leadingIndex, by: delta, minimumWeight: minimumWeight) != 0
    }

    // MARK: - join-with

    /// 隣のウィンドウと新しいコンテナを作る。
    ///
    /// 方向が決めるのは**新しいコンテナの向き**と**どちらの隣を取るか**の2つ。
    /// 横並びの中で `join-with down` と言えば「次の兄弟と縦のコンテナにまとめる」意味になる。
    ///
    /// - Returns: 木が変わったか。その方向に隣が無ければ `false`。
    @discardableResult
    public static func joinWith(_ node: WindowNode, direction: Direction) -> Bool {
        guard let parent = node.parent, let index = parent.index(of: node) else { return false }
        let neighbor = direction.isForward ? index + 1 : index - 1
        guard parent.children.indices.contains(neighbor) else { return false }

        let container = ContainerNode(orientation: direction.orientation)
        return parent.wrapChildren(at: index, and: neighbor, into: container)
    }

    // MARK: - layout

    /// 向きを候補の中で巡回させる。
    ///
    /// 対象がコンテナなら**そのコンテナ自身**の向きを、葉なら**親コンテナ**の向きを変える
    ///（i3 の `layout toggle split` と同じ。`focus parent` で上がっていれば
    /// そのコンテナが対象になる）。
    ///
    /// 現在の向きが候補に無ければ最初の候補にする。
    /// **利用者が明示的に選んだ向きは正規化で戻されない**（そうしないとキーが効かない）。
    ///
    /// - Returns: 向きが変わったか。
    @discardableResult
    public static func cycleOrientation(of node: Node, among candidates: [Orientation])
        -> Bool
    {
        guard !candidates.isEmpty else { return false }
        guard let target = (node as? ContainerNode) ?? node.parent else { return false }

        let next: Orientation
        if let current = candidates.firstIndex(of: target.orientation) {
            next = candidates[(current + 1) % candidates.count]
        } else {
            next = candidates[0]
        }

        guard next != target.orientation else { return false }
        target.orientation = next
        target.isOrientationExplicit = true
        return true
    }

    // MARK: - balance

    /// 分割の比率を均等に戻す（AeroSpace の `balance-sizes`）。
    ///
    /// リサイズを重ねて収拾がつかなくなったときの戻し先。**入れ子の中まで**均等にする。
    /// 一段だけ均すと、見た目には偏りが残ったままで「効かない」と読まれる。
    ///
    /// - Parameter node: 起点。葉を渡したときは親コンテナを均す
    ///   （`focus parent` で上げていなくても効くようにする）。
    /// - Returns: 比率が変わったか。既に均等なら `false`。
    @discardableResult
    public static func balance(_ node: Node) -> Bool {
        guard let container = (node as? ContainerNode) ?? node.parent else { return false }
        return balanceRecursively(container)
    }

    private static func balanceRecursively(_ container: ContainerNode) -> Bool {
        var changed = false
        let count = container.children.count
        if count > 1 {
            let even = Array(repeating: 1 / Double(count), count: count)
            // 誤差の範囲で既に均等なら触らない。呼び出し側が「変わっていない」ことを
            // 見て再配置を省けるようにする。
            if zip(container.weights, even).contains(where: { abs($0 - $1) > 1e-9 }) {
                container.setWeights(even)
                changed = true
            }
        }
        for child in container.children {
            guard let nested = child as? ContainerNode else { continue }
            if balanceRecursively(nested) { changed = true }
        }
        return changed
    }

    // MARK: - flatten

    /// 入れ子を全部ほどいて、ウィンドウをルート直下に並べ直す。
    ///
    /// 分割を積み重ねすぎて収拾がつかなくなったときの逃げ道
    ///（AeroSpace の `flatten-workspace-tree`）。**並び順は葉の深さ優先順を保つ**ので、
    /// 画面上の見た目の順番がそのまま列になる。
    ///
    /// - Returns: 形が変わったか。既に平らなら `false`。
    @discardableResult
    public static func flatten(_ root: ContainerNode) -> Bool {
        let leaves = root.windowNodes
        guard leaves.count != root.children.count else { return false }

        for leaf in leaves {
            leaf.parent?.remove(leaf)
        }
        // 残った空のコンテナを外す。**後ろから外す**（前から消すと添字がずれる）。
        for index in stride(from: root.children.count - 1, through: 0, by: -1) {
            root.remove(at: index)
        }
        for leaf in leaves {
            root.append(leaf)
        }
        return true
    }
}
