import CoreGraphics

/// Phase 1 の暫定レイアウト（spiral / フィボナッチ）。
///
/// 新しいウィンドウが直前に残った領域を半分ずつ取り、分割方向が交互に切り替わる。
///
/// ```
/// 2枚          3枚            4枚
/// ┌───┬───┐   ┌───┬───┐    ┌───┬───────┐
/// │ A │ B │   │   │ B │    │   │   B   │
/// │   │   │   │ A ├───┤    │ A ├───┬───┤
/// └───┴───┘   │   │ C │    │   │ C │ D │
///             └───┴───┘    └───┴───┴───┘
/// ```
///
/// Phase 2 で BSP ツリー（`LayoutEngine`）に置き換える。この形はツリーで言えば
/// 「右側の子を再帰的に分割し続ける」特殊形なので、丸めの方針ごとそのまま引き継げる。
public enum SimpleLayout {

    public enum Orientation: Sendable {
        case horizontal  // 左右に分ける
        case vertical  // 上下に分ける

        var flipped: Orientation {
            self == .horizontal ? .vertical : .horizontal
        }
    }

    /// 残り領域の進み方。
    public enum Style: Sendable {
        /// 新しいウィンドウが常に手前側（左／上）を取り、残り領域が右下へ降りていく。
        ///
        /// ```
        /// 4枚            5枚
        /// ┌───┬───────┐  ┌───┬───────┐
        /// │   │   B   │  │   │   B   │
        /// │ A ├───┬───┤  │ A ├───┬───┤
        /// │   │ C │ D │  │   │ C │ D │
        /// └───┴───┴───┘  │   │   ├───┤
        ///                │   │   │ E │
        ///                └───┴───┴───┘
        /// ```
        case dwindle

        /// 取る側も2回ごとに反転し、残り領域が 右→下→左→上 と時計回りに巻き込む。
        ///
        /// ```
        /// 4枚            5枚
        /// ┌───┬───────┐  ┌───┬───────┐
        /// │   │   B   │  │   │   B   │
        /// │ A ├───┬───┤  │ A ├───┬───┤
        /// │   │ D │ C │  │   │ E │   │
        /// └───┴───┴───┘  │   ├───┤ C │
        ///                │   │ D │   │
        ///                └───┴───┴───┘
        /// ```
        case spiral

        /// 分割 `index` 回目で、新しいウィンドウが手前側（左／上）を取るか。
        func takesLeadingSide(at index: Int) -> Bool {
            switch self {
            case .dwindle: true
            case .spiral: (index / 2) % 2 == 0
            }
        }
    }

    /// 領域を spiral 状に `count` 分割する。座標は AX 系。
    ///
    /// 最初の分割方向は領域の縦横比で決める（横長なら左右から）。
    /// AeroSpace の `default-root-container-orientation = 'auto'` と同じ考え方。
    ///
    /// 丸めの方針:
    /// **分割の境界だけを格子に載せ、残り側の終端は元の領域の終端に固定する。**
    /// こうすると分割間隔がギャップと厳密に一致し、外周も領域にぴったり接する。
    ///
    /// - Parameters:
    ///   - ratio: 各分割で手前側が取る割合。
    ///   - minimums: ウィンドウごとの最小寸法（登録順）。不明な要素は `.zero`。
    ///     アプリが指定より小さくならない場合、そのぶん兄弟が譲らないと
    ///     はみ出して重なる。学習した最小寸法を渡すと分割位置がそれを避ける。
    /// - Returns: 配置できない場合（枚数が 0 以下、領域が潰れている）は空配列。
    public static func spiral(
        count: Int,
        in area: CGRect,
        gaps: Gaps,
        scale: CGFloat = 2,
        ratio: CGFloat = 0.5,
        minimums: [CGSize] = [],
        style: Style = .dwindle
    ) -> [CGRect] {
        guard count > 0 else { return [] }

        let usable = Geometry.rounded(gaps.usableArea(in: area), scale: scale)
        guard usable.width > 0, usable.height > 0 else { return [] }

        // 範囲外の比率は分割の不変条件（手前側が領域内に収まる）を壊す。
        let ratio = min(max(ratio, 0), 1)

        var rects: [CGRect] = []
        rects.reserveCapacity(count)

        var remaining = usable
        var orientation: Orientation = usable.width >= usable.height ? .horizontal : .vertical

        for index in 0..<count {
            // 最後の1枚は残り全部を取る。これで右端・下端が領域にぴったり接する。
            guard index < count - 1 else {
                rects.append(remaining)
                break
            }
            // このウィンドウの最小寸法と、残りのウィンドウが必要とする最小寸法。
            // 残り領域は次に別軸で分割されるので、この軸方向には残り全員が
            // 領域いっぱいを使う。したがって残り側の要求は最大値を取る。
            let placedMinimum = extent(minimum(minimums, at: index), along: orientation)
            let remainingMinimum = (index + 1..<count)
                .map { extent(minimum(minimums, at: $0), along: orientation) }
                .max() ?? 0

            // 分割の向きに加えて「新しいウィンドウがどちら側を取るか」で
            // 残り領域の進み方が決まる（``Style`` 参照）。
            let takesLeadingSide = style.takesLeadingSide(at: index)

            let (placed, rest) = split(
                remaining, orientation: orientation, gaps: gaps, scale: scale, ratio: ratio,
                placedTakesLeadingSide: takesLeadingSide,
                placedMinimum: placedMinimum, remainingMinimum: remainingMinimum)
            rects.append(placed)
            remaining = rest
            orientation = orientation.flipped
        }
        return rects
    }

    private static func extent(_ size: CGSize, along orientation: Orientation) -> CGFloat {
        orientation == .horizontal ? size.width : size.height
    }

    private static func minimum(_ minimums: [CGSize], at index: Int) -> CGSize {
        index >= 0 && index < minimums.count ? minimums[index] : .zero
    }

    /// 領域を2つに割り、置くほうと残るほうを返す。
    ///
    /// `placedTakesLeadingSide` が `true` なら置くほうが手前側（左/上）、
    /// `false` なら奥側（右/下）を取る。どちらの場合も間隔はギャップと厳密に一致し、
    /// 元の領域の両端は保たれる。
    private static func split(
        _ rect: CGRect,
        orientation: Orientation,
        gaps: Gaps,
        scale: CGFloat,
        ratio: CGFloat,
        placedTakesLeadingSide: Bool,
        placedMinimum: CGFloat,
        remainingMinimum: CGFloat
    ) -> (placed: CGRect, remaining: CGRect) {
        let gap = orientation == .horizontal ? gaps.innerHorizontal : gaps.innerVertical
        let start = orientation == .horizontal ? rect.minX : rect.minY
        let end = orientation == .horizontal ? rect.maxX : rect.maxY
        let available = max(0, (end - start) - gap)

        let placedLength = leadingLength(
            available: available, ratio: ratio,
            leadingMinimum: placedMinimum, trailingMinimum: remainingMinimum)

        // 手前側の長さから境界を決める。置くほうが奥側なら、残るほうの長さで境界を決める。
        let leadingLengthValue = placedTakesLeadingSide ? placedLength : available - placedLength
        let boundary = Geometry.rounded(start + leadingLengthValue, scale: scale)
        let trailingStart = min(Geometry.rounded(boundary + gap, scale: scale), end)

        let leading = slice(rect, orientation: orientation, from: start, to: boundary)
        let trailing = slice(rect, orientation: orientation, from: trailingStart, to: end)

        return placedTakesLeadingSide ? (leading, trailing) : (trailing, leading)
    }

    /// 分割軸に沿って `from`〜`to` を切り出す。もう一方の軸は元のまま。
    private static func slice(
        _ rect: CGRect, orientation: Orientation, from: CGFloat, to: CGFloat
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            return CGRect(
                x: from, y: rect.minY, width: max(0, to - from), height: rect.height)
        case .vertical:
            return CGRect(
                x: rect.minX, y: from, width: rect.width, height: max(0, to - from))
        }
    }

    /// 置くほうに割り当てる長さ。最小寸法を尊重する。
    ///
    /// 両者の最小を同時に満たせない場合は、最小寸法に比例して不足を分け合う。
    /// どちらか一方だけを満たすと、割を食った側が一方的にはみ出して重なるため。
    private static func leadingLength(
        available: CGFloat,
        ratio: CGFloat,
        leadingMinimum: CGFloat,
        trailingMinimum: CGFloat
    ) -> CGFloat {
        let desired = available * ratio
        let lowerBound = min(leadingMinimum, available)
        let upperBound = available - trailingMinimum

        guard lowerBound <= upperBound else {
            // 双方の最小を満たせない。比例配分で不足を分け合う。
            let total = leadingMinimum + trailingMinimum
            guard total > 0 else { return desired }
            return available * (leadingMinimum / total)
        }
        return min(max(desired, lowerBound), upperBound)
    }
}
