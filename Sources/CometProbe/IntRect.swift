/// 整数の矩形。
///
/// 画像の中の範囲と、ウィンドウの座標の両方に使う。どちらも左上原点で、
/// **単位（画素か pt か）を揃えるのは呼び出し側の責任**。Retina では 1pt が
/// 複数の画素になりうるので、撮った画像と突き合わせる前に倍率をかける。
public struct IntRect: Equatable, Sendable, CustomStringConvertible {

    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// 自分が `other` に完全に収まっているか。
    public func isInside(_ other: IntRect) -> Bool {
        !isEmpty && x >= other.x && y >= other.y && maxX <= other.maxX && maxY <= other.maxY
    }

    /// 四辺すべてが許容差の内側にあるか。
    ///
    /// 位置だけでなく**大きさも見る**。位置が同じままリサイズされた場合を
    /// 「動いていない」と判定してしまうと、追従の失敗を取り逃がす。
    public func isNear(_ other: IntRect, tolerance: Int) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    /// 全体を倍率で拡大する。pt で計算した矩形を画像の画素へ写すため。
    public func scaled(by scale: Int) -> IntRect {
        IntRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
    }

    /// 中心を保ったまま正方形へ広げる。**枠からはみ出さないよう寄せる。**
    ///
    /// アイコンは正方形でないと歪む。切り出す前にここで揃える。
    public func squared(within bounds: IntRect) -> IntRect {
        let side = min(max(width, height), min(bounds.width, bounds.height))
        var origin = CGPointInt(
            x: x + (width - side) / 2,
            y: y + (height - side) / 2)
        origin.x = min(max(origin.x, bounds.x), bounds.maxX - side)
        origin.y = min(max(origin.y, bounds.y), bounds.maxY - side)
        return IntRect(x: origin.x, y: origin.y, width: side, height: side)
    }

    public var description: String { "(\(x), \(y)) \(width)x\(height)" }

    /// `x,y,w,h` の並びを読む。コマンドライン引数の形。
    public init?(commaSeparated text: String) {
        let parts = text.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        self.init(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}

/// 整数の点。`squared(within:)` の中だけで使う。
struct CGPointInt {
    var x: Int
    var y: Int
}
