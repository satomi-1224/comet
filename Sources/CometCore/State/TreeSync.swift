import CoreGraphics

/// 台帳（どのウィンドウがタイル対象か）とツリー（どう並んでいるか）を一致させる。
///
/// 追加・削除の経路は複数ある（走査・生成通知・破棄通知・最小化・フローティング切替）。
/// それぞれがツリーを直接いじると、どこかの経路を直し忘れたときにツリーだけがずれて、
/// 「閉じたウィンドウの領域が空いたまま」のような症状になる。**整合はここ一箇所に集める。**
public enum TreeSync {

    /// 新しいウィンドウをツリーのどこへ入れるか。
    public enum InsertionStrategy: String, Sendable, Equatable, CaseIterable {

        /// フォーカス中のウィンドウの**隣に並べる**。AeroSpace と同じ。
        ///
        /// ルート直下に並べていくと、開くたびに列が増える。
        case sibling

        /// フォーカス中のウィンドウの**領域を分割して入る**。分割の向きは親と逆になるので、
        /// 常に新しい方を選び続けると縦横交互に割れていく（dwindle）。
        ///
        /// ```
        /// 2枚          3枚          4枚            5枚
        /// ┌───┬───┐   ┌───┬───┐   ┌───┬───────┐   ┌───┬───────┐
        /// │ A │ B │   │   │ B │   │   │   B   │   │   │   B   │
        /// │   │   │   │ A ├───┤   │ A ├───┬───┤   │ A ├───┬───┤
        /// └───┴───┘   │   │ C │   │   │ C │ D │   │   │ C │ D │
        ///             └───┴───┘   └───┴───┴───┘   │   │   ├───┤
        ///                                         │   │   │ E │
        ///                                         └───┴───┴───┘
        /// ```
        case split
    }

    public struct Change: Equatable, Sendable {
        public var inserted: [CGWindowID] = []
        public var removed: [CGWindowID] = []

        public var isEmpty: Bool { inserted.isEmpty && removed.isEmpty }
    }

    /// - Parameters:
    ///   - tiled: タイル対象のウィンドウ。**並び順は新規追加のときだけ意味を持つ。**
    ///     既にツリーにあるウィンドウを並べ替えることはしない（勝手に入れ替わって見える）。
    ///   - focused: 新しいウィンドウを置く基準。この隣、またはこの領域を分割して入る。
    @discardableResult
    public static func reconcile(
        root: ContainerNode,
        tiled: [CGWindowID],
        focused: CGWindowID? = nil,
        strategy: InsertionStrategy = .split,
        normalization: NormalizationConfig = .default
    ) -> Change {
        var change = Change()

        var wanted = Set<CGWindowID>()
        var ordered: [CGWindowID] = []
        for id in tiled where wanted.insert(id).inserted {
            ordered.append(id)
        }

        // 先に外す。空になったコンテナは最後の正規化で畳まれる。
        // `windowNodes` は配列を作ってから返すので、走査中の削除は安全。
        for node in root.windowNodes where !wanted.contains(node.windowID) {
            node.parent?.remove(node)
            change.removed.append(node.windowID)
        }

        // 追加の基準は「今フォーカスされているウィンドウ」。基準を入れたばかりの
        // ウィンドウへ進めていくことで、複数の新規が渡された順に並ぶ。
        var anchor = focused.flatMap { root.findWindow($0) }
        for id in ordered where root.findWindow(id) == nil {
            let node = WindowNode(id)
            insert(node, near: anchor, in: root, strategy: strategy)
            anchor = node
            change.inserted.append(id)
        }

        Normalization.normalize(root, config: normalization)
        return change
    }

    private static func insert(
        _ node: WindowNode,
        near anchor: WindowNode?,
        in root: ContainerNode,
        strategy: InsertionStrategy
    ) {
        guard let anchor, let parent = anchor.parent, let index = parent.index(of: anchor) else {
            root.append(node)
            return
        }

        switch strategy {
        case .sibling:
            parent.insert(node, at: index + 1)

        case .split:
            // 親に兄弟が居ないうちは親の向きのまま並べる。ここで分割すると
            // 1枚目と2枚目が画面の縦横比と逆に並んでしまう
            //（横長の画面なら最初の分割は左右であってほしい）。
            guard parent.children.count > 1 else {
                parent.insert(node, at: index + 1)
                return
            }
            // 基準のウィンドウを新しいコンテナに包み、その中を2つで分ける。
            // 差し替えなので領域（取り分）は変わらない。
            let container = ContainerNode(orientation: parent.orientation.flipped)
            parent.replace(at: index, with: container)
            container.append(anchor)
            container.append(node)
        }
    }
}
