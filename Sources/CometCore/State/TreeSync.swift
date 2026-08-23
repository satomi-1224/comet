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
    ///   - split: `split` コマンド（i3 の `split h` / `split v`）で予約された分割の向き。
    ///     **基準のウィンドウが一致するときだけ**効く。
    @discardableResult
    public static func reconcile(
        root: ContainerNode,
        tiled: [CGWindowID],
        focused: CGWindowID? = nil,
        strategy: InsertionStrategy = .split,
        normalization: NormalizationConfig = .default,
        split: (windowID: CGWindowID, orientation: Orientation)? = nil
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
        // 予約された分割は**最初の1枚にだけ**効かせる。2枚目からは通常の入り方に戻す
        //（i3 も split したあと1枚入れば予約は消える）。
        var pendingSplit = split.flatMap { $0.windowID == anchor?.windowID ? $0.orientation : nil }
        for id in ordered where root.findWindow(id) == nil {
            let node = WindowNode(id)
            insert(node, near: anchor, in: root, strategy: strategy, split: pendingSplit)
            pendingSplit = nil
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
        strategy: InsertionStrategy,
        split: Orientation? = nil
    ) {
        guard let anchor, let parent = anchor.parent, let index = parent.index(of: anchor) else {
            root.append(node)
            return
        }

        // `split` コマンドで向きを指定されていれば、設定の入り方より優先する。
        if let split {
            // 親が既にその向きなら、包まずに隣へ並べれば同じ形になる。
            // **余計な入れ子を作らない**（作っても正規化で潰れるので形は同じだが、
            // 潰れる前の1フレームで比率が変わって見える）。
            if parent.orientation == split {
                parent.insert(node, at: index + 1)
                return
            }
            let container = ContainerNode(orientation: split)
            parent.replace(at: index, with: container)
            // **利用者が選んだ向きなので正規化で反転させない。**
            container.isOrientationExplicit = true
            container.append(anchor)
            container.append(node)
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
