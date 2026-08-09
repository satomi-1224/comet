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

    /// 領域を spiral 状に `count` 分割する。座標は AX 系。
    ///
    /// 最初の分割方向は領域の縦横比で決める（横長なら左右から）。
    /// AeroSpace の `default-root-container-orientation = 'auto'` と同じ考え方。
    ///
    /// 丸めの方針:
    /// **分割の境界だけを格子に載せ、残り側の終端は元の領域の終端に固定する。**
    /// こうすると分割間隔がギャップと厳密に一致し、外周も領域にぴったり接する。
    ///
    /// - Parameter ratio: 各分割で手前側が取る割合。
    /// - Returns: 配置できない場合（枚数が 0 以下、領域が潰れている）は空配列。
    public static func spiral(
        count: Int,
        in area: CGRect,
        gaps: Gaps,
        scale: CGFloat = 2,
        ratio: CGFloat = 0.5
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
            let (first, rest) = split(
                remaining, orientation: orientation, gaps: gaps, scale: scale, ratio: ratio)
            rects.append(first)
            remaining = rest
            orientation = orientation.flipped
        }
        return rects
    }

    /// 領域を2つに割る。手前側が `ratio`、残りが元の終端まで。
    private static func split(
        _ rect: CGRect,
        orientation: Orientation,
        gaps: Gaps,
        scale: CGFloat,
        ratio: CGFloat
    ) -> (first: CGRect, rest: CGRect) {
        switch orientation {
        case .horizontal:
            let gap = gaps.innerHorizontal
            let available = max(0, rect.width - gap)
            let boundary = Geometry.rounded(rect.minX + available * ratio, scale: scale)
            let restStart = min(Geometry.rounded(boundary + gap, scale: scale), rect.maxX)
            return (
                CGRect(
                    x: rect.minX, y: rect.minY,
                    width: max(0, boundary - rect.minX), height: rect.height),
                CGRect(
                    x: restStart, y: rect.minY,
                    width: max(0, rect.maxX - restStart), height: rect.height)
            )

        case .vertical:
            let gap = gaps.innerVertical
            let available = max(0, rect.height - gap)
            let boundary = Geometry.rounded(rect.minY + available * ratio, scale: scale)
            let restStart = min(Geometry.rounded(boundary + gap, scale: scale), rect.maxY)
            return (
                CGRect(
                    x: rect.minX, y: rect.minY,
                    width: rect.width, height: max(0, boundary - rect.minY)),
                CGRect(
                    x: rect.minX, y: restStart,
                    width: rect.width, height: max(0, rect.maxY - restStart))
            )
        }
    }
}
