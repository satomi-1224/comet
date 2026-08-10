import CoreGraphics

/// 設定に書かれた色。**AppKit に依存しない形**で保持する。
///
/// 設定の読み込み（`CometConfig`）と描画（`CometDecoration`）の両方から使うので、
/// `NSColor` ではなく成分そのままで持つ。
public struct RGBAColor: Equatable, Sendable {

    /// 0...1。
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    /// `#RGB` / `#RRGGBB` / `#RRGGBBAA` を解釈する。`#` は省略できる。
    ///
    /// 桁数が合わない・16進として読めないものは `nil`。設定の打ち間違いを
    /// 黙って黒にすると原因が分からないので、失敗として返す。
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }

        func component(_ range: Range<String.Index>) -> Double? {
            guard let value = UInt8(digits[range], radix: 16) else { return nil }
            return Double(value) / 255
        }

        switch digits.count {
        case 3:
            // #RGB は各桁を2回繰り返した #RRGGBB と同じ意味。
            let expanded = digits.map { "\($0)\($0)" }.joined()
            self.init(hex: expanded)
            return
        case 6, 8:
            var values: [Double] = []
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                guard let value = component(index..<next) else { return nil }
                values.append(value)
                index = next
            }
            self.init(
                red: values[0], green: values[1], blue: values[2],
                alpha: values.count == 4 ? values[3] : 1)
        default:
            return nil
        }
    }

    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

/// フォーカス枠線の見た目。
public struct BorderStyle: Equatable, Sendable {

    public var isEnabled: Bool
    public var width: CGFloat
    public var radius: CGFloat
    public var focusedColor: RGBAColor

    public init(
        isEnabled: Bool = true,
        width: CGFloat = 2,
        radius: CGFloat = 10,
        focusedColor: RGBAColor = RGBAColor(hex: "#7aa2f7") ?? .clear
    ) {
        self.isEnabled = isEnabled
        self.width = max(0, width)
        self.radius = max(0, radius)
        self.focusedColor = focusedColor
    }

    /// ウィンドウ矩形に対する枠線ウィンドウの矩形。
    ///
    /// **ウィンドウと同一にすると枠が中身に被る。** 線の幅だけ外へ広げて、
    /// ギャップの中に枠が描かれるようにする（gaps 5pt なら width 2pt が収まる）。
    public func frame(around rect: CGRect) -> CGRect {
        rect.insetBy(dx: -width, dy: -width)
    }
}

/// ワークスペースインジケータの出し方。
public enum IndicatorStyle: String, Sendable, Equatable, CaseIterable {
    /// メニューバーに常駐。
    case menubar
    /// 切替時に画面中央へ一瞬出す。
    case hud
    case both
    case off

    public var showsMenubar: Bool { self == .menubar || self == .both }
    public var showsHUD: Bool { self == .hud || self == .both }
}
