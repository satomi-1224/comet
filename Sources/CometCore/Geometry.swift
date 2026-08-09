import CoreGraphics

/// 座標系の変換と丸め。
///
/// macOS には原点の異なる2つの座標系が併存する。
///
/// | 座標系 | 原点 | Y軸 | 使う API |
/// |---|---|---|---|
/// | AppKit | プライマリの**左下** | 上向き | `NSScreen.frame`, `NSWindow.frame` |
/// | CG / AX | プライマリの**左上** | 下向き | `CGDisplayBounds`, `kAXPositionAttribute` |
///
/// comet は内部状態を全て CG/AX 座標系で保持し、AppKit に渡す直前だけ変換する。
///
/// - Important: 変換に使う `primaryMaxY` は**キャッシュしないこと**。
///   モニタの付け替えで変わるため、古い値を使うとウィンドウが画面外へ飛ぶ。
public enum Geometry {

    /// AppKit 座標（左下原点）→ AX 座標（左上原点）。
    public static func toAX(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    /// AX 座標（左上原点）→ AppKit 座標（左下原点）。
    ///
    /// 式が ``toAX(_:primaryMaxY:)`` と同一なのは変換が対合だからで、誤りではない。
    public static func toAppKit(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    /// 値をピクセル格子に載せる。`scale` は `backingScaleFactor`（Retina なら 2）。
    public static func rounded(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    /// 矩形を格子に載せる。
    ///
    /// 幅と高さではなく**始端と終端**を丸める。幅を丸めると終端が格子から外れ、
    /// 隣接するウィンドウとの間に半端な隙間が残る。
    public static func rounded(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        let minX = rounded(rect.minX, scale: scale)
        let minY = rounded(rect.minY, scale: scale)
        let maxX = rounded(rect.maxX, scale: scale)
        let maxY = rounded(rect.maxY, scale: scale)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 許容誤差つきの矩形比較。
    ///
    /// AX でサイズを設定してもアプリ側の制約で 1pt 未満ずれることがあり、
    /// 厳密比較だと無意味な再適用を繰り返す。
    public static func isApproximatelyEqual(
        _ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
