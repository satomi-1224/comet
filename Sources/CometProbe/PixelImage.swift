import Foundation

/// 画素の色（不透明成分だけ）。
///
/// アルファは持たない。**撮った画面は合成後の不透明な絵**なので、
/// 透過で描いたものも比較の時点では不透明な色になっている。
public struct PixelColor: Equatable, Sendable, CustomStringConvertible {

    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 設定ファイルと同じ綴り（`#rrggbb`）で書けるようにする。
    /// 検証したい色を設定に書いた文字列のまま渡せる。
    public init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xff),
            green: UInt8((value >> 8) & 0xff),
            blue: UInt8(value & 0xff))
    }

    /// 各成分の差が許容差の内側か。
    ///
    /// 縁の反エイリアス、画面の色空間（P3）から sRGB への変換、動画の圧縮で
    /// 数値は必ず少しずれる。厳密一致で判定してはいけない。
    public func isNear(_ other: PixelColor, tolerance: Int) -> Bool {
        abs(Int(red) - Int(other.red)) <= tolerance
            && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance
    }

    public var description: String {
        String(format: "#%02x%02x%02x", Int(red), Int(green), Int(blue))
    }
}

/// 一致した色が占める範囲。
public struct ColorMatch: Equatable, Sendable {
    public let rect: IntRect
    public let count: Int
}

/// 2枚の画像で変わった画素の数。
public struct PixelDiff: Equatable, Sendable {
    public let count: Int
    public let total: Int
}

/// 矩形の四辺に、その色がどれだけ乗っているか（0〜1）。
public struct EdgeCoverage: Equatable, Sendable {
    public let top: Double
    public let bottom: Double
    public let left: Double
    public let right: Double

    /// 最も乗っていない辺。判定はここで見る。
    /// 3辺だけ描かれている状態を「出ている」と数えないため。
    public var minimum: Double { min(min(top, bottom), min(left, right)) }
}

/// 撮った画面。
///
/// 画素は RGBA が1画素あたり4バイト、行の詰め物なしで並んでいる。
/// PNG の読み込みは呼び出し側（`cometprobe`）が行い、ここは並びだけを扱う。
public struct PixelImage: Sendable {

    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public var bounds: IntRect { IntRect(x: 0, y: 0, width: width, height: height) }

    private var isConsistent: Bool { bytes.count >= width * height * 4 && width > 0 && height > 0 }

    public func color(x: Int, y: Int) -> PixelColor? {
        guard isConsistent, x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = (y * width + x) * 4
        return PixelColor(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2])
    }

    /// 範囲の指定を検算する。**画像の外を指した指定は判定不能として返す**。
    /// 黙って切り詰めると、撮り方や倍率の間違いが「一致しなかった」に化けて
    /// 原因を追えなくなる。
    private func resolve(_ region: IntRect?) -> IntRect? {
        guard isConsistent else { return nil }
        guard let region else { return bounds }
        return region.isInside(bounds) ? region : nil
    }

    /// その色が描かれている範囲。
    ///
    /// - Important: 一致した画素**すべて**を囲む。画面の別の場所に同じ色が
    ///   写り込んでいると巨大な矩形になるので、位置の判定には
    ///   `edgeCoverage(of:)` を使うか、範囲を限って呼ぶ。
    public func boundingBox(
        matching color: PixelColor, tolerance: Int, in region: IntRect? = nil
    ) -> ColorMatch? {
        guard let area = resolve(region) else { return nil }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var count = 0
        for y in area.y..<area.maxY {
            for x in area.x..<area.maxX {
                guard let pixel = self.color(x: x, y: y),
                    pixel.isNear(color, tolerance: tolerance)
                else {
                    continue
                }
                count += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard count > 0 else { return nil }
        return ColorMatch(
            rect: IntRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
            count: count)
    }

    /// 矩形の四辺に沿って、その色がどれだけ乗っているかを測る。
    ///
    /// - Parameters:
    ///   - lineWidth: 辺を何画素の帯として見るか。1画素だけを厳密に見ると、
    ///     反エイリアスや丸めで1画素ずれただけで落ちる。
    ///   - inset: 辺の両端を何画素切るか。**角丸の円弧は辺の直線上に無い**ので、
    ///     端まで数えると必ず欠ける。枠線の角丸の半径より少し大きく取る。
    public func edgeCoverage(
        of rect: IntRect, color: PixelColor, tolerance: Int, lineWidth: Int = 1, inset: Int = 0
    ) -> EdgeCoverage? {
        guard resolve(rect) != nil, lineWidth > 0 else { return nil }

        /// 帯のどこか1画素でも一致すれば、その位置は「乗っている」と数える。
        func ratio(along positions: [Int], band: [Int], horizontal: Bool) -> Double {
            guard !positions.isEmpty else { return 0 }
            var hit = 0
            for position in positions {
                let matched = band.contains { offset in
                    let x = horizontal ? position : offset
                    let y = horizontal ? offset : position
                    return self.color(x: x, y: y)?.isNear(color, tolerance: tolerance) == true
                }
                if matched { hit += 1 }
            }
            return Double(hit) / Double(positions.count)
        }

        let columns = Array((rect.x + inset)..<(rect.maxX - inset))
        let rows = Array((rect.y + inset)..<(rect.maxY - inset))
        let topBand = Array(rect.y..<min(rect.y + lineWidth, rect.maxY))
        let bottomBand = Array(max(rect.maxY - lineWidth, rect.y)..<rect.maxY)
        let leftBand = Array(rect.x..<min(rect.x + lineWidth, rect.maxX))
        let rightBand = Array(max(rect.maxX - lineWidth, rect.x)..<rect.maxX)

        return EdgeCoverage(
            top: ratio(along: columns, band: topBand, horizontal: true),
            bottom: ratio(along: columns, band: bottomBand, horizontal: true),
            left: ratio(along: rows, band: leftBand, horizontal: false),
            right: ratio(along: rows, band: rightBand, horizontal: false))
    }

    /// 変わった画素の数。
    ///
    /// 大きさの違う画像や、はみ出した範囲は `nil` を返す。
    /// 「0 画素の差」と「比べられなかった」を混同すると、
    /// 出ていないものを「変わらなかった」と誤読する。
    public func differingPixels(
        from other: PixelImage, tolerance: Int, in region: IntRect? = nil
    ) -> PixelDiff? {
        guard width == other.width, height == other.height else { return nil }
        guard let area = resolve(region), other.resolve(region) != nil else { return nil }
        var differing = 0
        for y in area.y..<area.maxY {
            for x in area.x..<area.maxX {
                guard let mine = self.color(x: x, y: y), let theirs = other.color(x: x, y: y) else {
                    return nil
                }
                if !mine.isNear(theirs, tolerance: tolerance) { differing += 1 }
            }
        }
        return PixelDiff(count: differing, total: area.width * area.height)
    }
}
