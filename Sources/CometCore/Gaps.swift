import CoreGraphics

/// ウィンドウ間および画面端との余白。
///
/// 座標は AX 系（左上原点・Y は下向き）で扱うため、**「上」は minY 側**であることに注意。
public struct Gaps: Equatable, Sendable {

    /// 左右に隣接するウィンドウの間隔。
    public var innerHorizontal: CGFloat
    /// 上下に隣接するウィンドウの間隔。
    public var innerVertical: CGFloat

    public var outerTop: CGFloat
    public var outerBottom: CGFloat
    public var outerLeft: CGFloat
    public var outerRight: CGFloat

    public static let zero = Gaps(inner: 0, outer: 0)

    public init(
        innerHorizontal: CGFloat,
        innerVertical: CGFloat,
        outerTop: CGFloat,
        outerBottom: CGFloat,
        outerLeft: CGFloat,
        outerRight: CGFloat
    ) {
        self.innerHorizontal = innerHorizontal
        self.innerVertical = innerVertical
        self.outerTop = outerTop
        self.outerBottom = outerBottom
        self.outerLeft = outerLeft
        self.outerRight = outerRight
    }

    /// 内側・外側をそれぞれ一律に指定する簡易イニシャライザ。
    public init(inner: CGFloat, outer: CGFloat) {
        self.init(
            innerHorizontal: inner, innerVertical: inner,
            outerTop: outer, outerBottom: outer, outerLeft: outer, outerRight: outer)
    }

    /// 外周ギャップを差し引いた配置可能領域。
    ///
    /// ギャップが領域より大きい場合は寸法を 0 に丸める。
    /// 負の寸法を持つ `CGRect` を作らないこと（`CGRect.width` は絶対値を返すため、
    /// 負の寸法は下流で符号を失って発見しづらいバグになる）。
    public func usableArea(in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + outerLeft,
            y: rect.minY + outerTop,
            width: max(0, rect.width - outerLeft - outerRight),
            height: max(0, rect.height - outerTop - outerBottom))
    }
}
