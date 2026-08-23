import CoreGraphics

/// ひとつの分割境界。**利用者が縁をドラッグしたときの受け皿。**
///
/// 動いた辺をここへ突き合わせて、対応するコンテナの比率を書き換える。
/// ウィンドウ単体のサイズを直接変えることはできず、常に境界の移動になる。
public struct SplitBoundary {

    /// この境界を持つコンテナ。比率を書き換える先。
    ///
    /// 木が変わると切り離されたコンテナを指したままになりうる。書き換える前に
    /// 今のルートに繋がっているかを確かめること。
    public let container: ContainerNode

    /// 境界の手前側にある子の添字。境界は `leadingIndex` と `leadingIndex + 1` の間にある。
    public let leadingIndex: Int

    public let orientation: Orientation

    /// 手前側の終端（＝境界の座標）。奥側は `position + gap` から始まる。
    public let position: CGFloat

    public let gap: CGFloat

    /// このコンテナが子に配分できる長さ（間隔を除いたもの）。
    ///
    /// 境界の移動量を比率の変化量へ直すのに使う。
    public let available: CGFloat

    /// 境界を `value` へ動かすとき、手前側の子の比率をどれだけ変えればよいか。
    ///
    /// - Returns: 配分できる長さが無ければ `nil`（比率で表せない）。
    public func weightDelta(movingTo value: CGFloat) -> Double? {
        guard available > 0 else { return nil }
        return Double((value - position) / available)
    }
}

/// BSP ツリーとモニタ矩形から、各ウィンドウの目標矩形を計算する。
///
/// **副作用を持たない。単体テストの主対象。**
///
/// ## 丸めの方針
///
/// 分割の境界だけを格子に載せ、**最後の子の終端は領域の終端に固定する。**
/// こうすると間隔がギャップと厳密に一致し、外周も領域にぴったり接する。
/// 幅を丸めると終端が格子から外れ、隣との間に半端な隙間が残る。
public enum LayoutEngine {

    /// 最小寸法の合計が領域に収まらなかった分割。**重なりが避けられない状態。**
    ///
    /// macOS のアプリは指定より小さくならない（Safari は幅 574、Parsec は 640 が下限。
    /// いずれも実測）。合計が領域を超えると、どう配っても隣にはみ出す。
    ///
    /// **黙って重ねてはいけない。** 利用者から見れば「タイリングが壊れている」ので、
    /// 何が起きているのかと打つ手（1枚を浮かせる・別のワークスペースへ移す）を
    /// 伝えられるように、ここで事実として持ち出す。
    public struct Overflow: Equatable, Sendable {
        /// 収まらなかった分割に属するウィンドウ。
        public let windowIDs: [CGWindowID]
        /// 分割の向き。`horizontal` なら幅が足りない。
        public let axis: Orientation
        /// 配れる長さ。
        public let available: CGFloat
        /// 最小寸法の合計。
        public let required: CGFloat

        public var shortfall: CGFloat { required - available }
    }

    public struct Result {
        /// ウィンドウ ID → 目標矩形（AX 座標系）。
        public let frames: [CGWindowID: CGRect]
        /// 適用順。葉の深さ優先順なので、同じ木からは常に同じ順になる。
        public let order: [CGWindowID]
        /// 分割境界。要素数は各コンテナの `children.count - 1` の総和。
        public let boundaries: [SplitBoundary]
        /// 最小寸法が収まらなかった分割。空なら重なりは起きない。
        public var overflows: [Overflow] = []

        /// `SplitBoundary` がコンテナを指すため `Result` は `Sendable` ではない。
        /// 共有された定数にはできないので、都度作る。
        public static var empty: Result { Result(frames: [:], order: [], boundaries: []) }
    }

    /// - Parameters:
    ///   - area: モニタの `visibleFrame`（AX 座標系）。
    ///   - scale: `backingScaleFactor`。Retina なら 2。
    ///   - minimums: ウィンドウごとの最小寸法。アプリが指定より小さくならない場合、
    ///     そのぶん兄弟が譲らないとはみ出して重なる。学習した値を渡すと分割位置がそれを避ける。
    ///   - fullscreen: 領域いっぱいに広げるウィンドウ（`fullscreen` コマンド）。
    ///     **他のウィンドウの矩形は変えない。** 覆うだけにしておけば、解除したときに
    ///     元の配置がそのまま出てくる。ツリーに無い id は無視する。
    public static func compute(
        root: ContainerNode,
        area: CGRect,
        gaps: Gaps,
        scale: CGFloat = 2,
        minimums: [CGWindowID: CGSize] = [:],
        fullscreen: CGWindowID? = nil
    ) -> Result {
        guard !root.isEmpty else { return .empty }

        let usable = Geometry.rounded(gaps.usableArea(in: area), scale: scale)
        guard usable.width > 0, usable.height > 0 else { return .empty }

        var worker = Worker(gaps: gaps, scale: scale, minimums: minimums)
        worker.place(root, in: usable)

        var frames = worker.frames
        if let fullscreen, frames[fullscreen] != nil {
            frames[fullscreen] = usable
        }
        return Result(
            frames: frames, order: worker.order, boundaries: worker.boundaries,
            overflows: worker.overflows)
    }

    /// 再帰の途中の状態を持つ。`LayoutEngine` 自体は状態を持たない。
    private struct Worker {

        let gaps: Gaps
        let scale: CGFloat
        let minimums: [CGWindowID: CGSize]

        var frames: [CGWindowID: CGRect] = [:]
        var order: [CGWindowID] = []
        var boundaries: [SplitBoundary] = []
        var overflows: [LayoutEngine.Overflow] = []

        mutating func place(_ node: Node, in rect: CGRect) {
            if let window = node as? WindowNode {
                frames[window.windowID] = rect
                order.append(window.windowID)
                return
            }
            guard let container = node as? ContainerNode, !container.isEmpty else { return }

            let count = container.children.count
            let axis = container.orientation
            let gap = innerGap(axis)
            let start = axis == .horizontal ? rect.minX : rect.minY
            let end = axis == .horizontal ? rect.maxX : rect.maxY
            let available = max(0, (end - start) - gap * CGFloat(count - 1))

            // 不変条件が破れていても落ちないようにする。常駐プロセスなので、
            // 内部矛盾で落ちるよりは均等に並べて動き続けるほうがまだ良い。
            let weights =
                container.weights.count == count
                ? container.weights
                : Array(repeating: 1 / Double(count), count: count)

            let minimums = container.children.map { minimumExtent($0, along: axis) }
            // **収まらないことは事実として持ち出す。** ここで黙ると、画面上は
            // ただ重なって見えるだけで原因が分からない。
            let totalMinimum = minimums.reduce(0, +)
            if totalMinimum > available {
                overflows.append(
                    LayoutEngine.Overflow(
                        windowIDs: container.windowIDs, axis: axis,
                        available: available, required: totalMinimum))
            }
            let lengths = Self.distribute(
                available: available, weights: weights, minimums: minimums)

            var offset = start
            for (index, child) in container.children.enumerated() {
                let childEnd: CGFloat
                if index == count - 1 {
                    // 最後の子は残り全部を取る。丸めの累積が隙間として残らない。
                    childEnd = end
                } else {
                    childEnd = min(Geometry.rounded(offset + lengths[index], scale: scale), end)
                    boundaries.append(
                        SplitBoundary(
                            container: container, leadingIndex: index, orientation: axis,
                            position: childEnd, gap: gap, available: available))
                }

                place(
                    child,
                    in: Self.slice(rect, along: axis, from: offset, to: max(offset, childEnd)))

                // 領域を使い切ったら、以降の子は終端に潰れる。領域の外へは出さない。
                offset = min(Geometry.rounded(childEnd + gap, scale: scale), end)
            }
        }

        private func innerGap(_ axis: Orientation) -> CGFloat {
            axis == .horizontal ? gaps.innerHorizontal : gaps.innerVertical
        }

        /// ノードが軸方向に必要とする最小の長さ。
        ///
        /// 分割軸が同じなら子は長さを**分け合う**ので合計 + 間隔。
        /// 直交するなら子は領域を**共有する**ので最大値。
        private func minimumExtent(_ node: Node, along axis: Orientation) -> CGFloat {
            if let window = node as? WindowNode {
                guard let size = minimums[window.windowID] else { return 0 }
                return axis == .horizontal ? size.width : size.height
            }
            guard let container = node as? ContainerNode, !container.isEmpty else { return 0 }

            let extents = container.children.map { minimumExtent($0, along: axis) }
            guard container.orientation == axis else {
                return extents.max() ?? 0
            }
            return extents.reduce(0, +) + innerGap(axis) * CGFloat(container.children.count - 1)
        }

        /// 長さ `available` を比率に応じて配り、各子の下限を尊重する。
        ///
        /// 下限に届かない子を下限で固定し、不足ぶんを残りから比率に応じて取る。
        /// 固定した結果さらに別の子が下限を割ることがあるので、動かなくなるまで繰り返す。
        /// 固定は一方向にしか進まないので、最大でも子の数だけ回れば止まる。
        static func distribute(
            available: CGFloat, weights: [Double], minimums: [CGFloat]
        ) -> [CGFloat] {
            let count = weights.count
            guard count > 0, count == minimums.count else { return [] }
            guard available > 0 else { return Array(repeating: 0, count: count) }

            let totalMinimum = minimums.reduce(0, +)
            if totalMinimum > available {
                // 全員の下限を同時に満たせない。下限に比例して不足を分け合う。
                // 一部だけ満たすと、割を食った側が一方的にはみ出して重なる。
                guard totalMinimum > 0 else { return weights.map { available * CGFloat($0) } }
                return minimums.map { available * ($0 / totalMinimum) }
            }

            var lengths = Array(repeating: CGFloat(0), count: count)
            var isPinned = Array(repeating: false, count: count)

            while true {
                var pinnedTotal: CGFloat = 0
                var freeWeight: Double = 0
                var freeCount = 0
                for index in 0..<count {
                    if isPinned[index] {
                        lengths[index] = minimums[index]
                        pinnedTotal += minimums[index]
                    } else {
                        freeWeight += weights[index]
                        freeCount += 1
                    }
                }
                guard freeCount > 0 else { break }

                let freeLength = max(0, available - pinnedTotal)
                var pinnedSomething = false
                for index in 0..<count where !isPinned[index] {
                    let share =
                        freeWeight > 0
                        ? CGFloat(weights[index] / freeWeight)
                        : 1 / CGFloat(freeCount)
                    lengths[index] = freeLength * share
                    if lengths[index] < minimums[index] {
                        isPinned[index] = true
                        lengths[index] = minimums[index]
                        pinnedSomething = true
                    }
                }
                if !pinnedSomething { break }
            }
            return lengths
        }

        /// 分割軸に沿って `from`〜`to` を切り出す。もう一方の軸は元のまま。
        static func slice(
            _ rect: CGRect, along axis: Orientation, from: CGFloat, to: CGFloat
        ) -> CGRect {
            switch axis {
            case .horizontal:
                CGRect(x: from, y: rect.minY, width: max(0, to - from), height: rect.height)
            case .vertical:
                CGRect(x: rect.minX, y: from, width: rect.width, height: max(0, to - from))
            }
        }
    }
}

// MARK: - 動いた辺と境界の突き合わせ

extension LayoutEngine.Result {

    /// コンテナが子に配分できた長さ。点数を比率へ直すのに使う。
    ///
    /// - Returns: 分割を持たないコンテナ（子が1つ、または木に無い）なら `nil`。
    public func availableLength(of container: ContainerNode) -> CGFloat? {
        boundaries.first { $0.container === container }?.available
    }

    /// 別のレイアウトで得た境界に対応する、こちらの境界。
    ///
    /// 比率を書き換えたあとの座標を引くために使う。同じ分割かどうかは
    /// 「同じコンテナの同じ位置」で判断する（座標は変わっているので使えない）。
    public func boundary(like other: SplitBoundary) -> SplitBoundary? {
        boundaries.first {
            $0.container === other.container && $0.leadingIndex == other.leadingIndex
        }
    }

    /// 動いた辺がどの境界にあたるかの照合結果。
    public struct BoundaryMatch {
        public let boundary: SplitBoundary
        /// 境界の座標から、観測された辺の座標までの差。
        ///
        /// 手前側のウィンドウなら 0（終端が境界そのもの）、
        /// 奥側なら `gap`（始端が「境界 + 間隔」）。
        public let edgeOffset: CGFloat

        /// 辺が `value` へ動いたときの、境界の新しい座標。
        public func boundaryPosition(forEdge value: CGFloat) -> CGFloat {
            value - edgeOffset
        }
    }

    /// ウィンドウの辺が、どの分割境界にあたるかを探す。
    ///
    /// 探す範囲を**そのウィンドウの祖先コンテナ**に限り、近い祖先を優先する。
    /// 座標だけで探すと、入れ子の別の枝にある同座標の境界を掴んでしまい、
    /// 引っ張ったのとは無関係なウィンドウが動く。
    public func match(
        edge value: CGFloat, of node: WindowNode, orientation: Orientation, tolerance: CGFloat
    ) -> BoundaryMatch? {
        for ancestor in node.ancestors {
            guard ancestor.orientation == orientation else { continue }
            for boundary in boundaries
            where boundary.container === ancestor && boundary.orientation == orientation {
                if abs(boundary.position - value) <= tolerance {
                    return BoundaryMatch(boundary: boundary, edgeOffset: 0)
                }
                if abs(boundary.position + boundary.gap - value) <= tolerance {
                    return BoundaryMatch(boundary: boundary, edgeOffset: boundary.gap)
                }
            }
        }
        return nil
    }
}
