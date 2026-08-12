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

    /// ログに出す矩形の書き方。**撮った画面の画素と突き合わせられるように整数で出す。**
    public static func rendered(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))"
    }


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

    /// 非表示ワークスペースのウィンドウを退避させる座標（AX 座標系）。
    ///
    /// **union 矩形の右下、両軸とも画面外へ逃がす。**
    ///
    /// ## 片方だけでは隠れない（実測）
    ///
    /// macOS は AX で設定した位置を**必ず画面内へ引き戻す**。アプリ側の
    /// `constrainFrameRect` が働き、要求した座標は次のように丸められる。
    ///
    /// | 要求 | 実際（2560×1664 の画面） |
    /// |---|---|
    /// | `(0, 101664)` | `(0, 1618)` — **全幅 46pt の帯が画面下に残る** |
    /// | `(0, -100000)` | `(0, 56)` — メニューバーの下に戻される |
    /// | `(102560, 101664)` | `(2559, 1618)` — 1pt × 46pt の角だけ |
    ///
    /// つまり「画面外へ出す」ことはできず、**残る面積を最小にする**のが限界。
    /// 両軸を外へ出せば右下隅の 1pt 幅まで追い込める。AeroSpace も同じ位置に落ちる
    /// （実測で `(2559, 1618)`）。
    ///
    /// - 寸法 0 の矩形は「そこに画面がある」ことを意味しないので union に混ぜない。
    ///   混ぜると退避先が無意味に遠ざかる。
    ///
    /// - Important: モニタを付け替えると union が変わる。**退避中のウィンドウを
    ///   新しい退避先へ動かし直さないと、画面の中に現れる**（設計書 §7.6 手順5）。
    public static func stashOrigin(outside monitors: [CGRect], margin: CGFloat = 100_000)
        -> CGPoint
    {
        let union = monitors.filter { !$0.isEmpty }.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return CGPoint(x: margin, y: margin) }
        // x は「1pt だけ重ねる」位置を要求する。完全に画面外だと引き戻しが働いて
        // 40pt 残るので、あえて重ねたほうが隠れる（上の表を参照）。
        // y は何を要求しても引き戻されるので、遠くへ投げて成り行きに任せる。
        return CGPoint(x: union.maxX - 1, y: union.maxY + margin)
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
