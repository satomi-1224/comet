import CoreGraphics

/// 分割の向き。
///
/// 座標は AX 系（左上原点・Y は下向き）で扱うため、`vertical` の「先頭側」は上端になる。
public enum Orientation: String, Sendable, Equatable, CaseIterable {
    /// 子を左右に並べる。分割軸は X。
    case horizontal
    /// 子を上下に並べる。分割軸は Y。
    case vertical

    public var flipped: Orientation {
        self == .horizontal ? .vertical : .horizontal
    }

    /// ログとテストで木の形を短く書くための記号。
    public var symbol: String {
        self == .horizontal ? "H" : "V"
    }

    /// 領域の縦横比から向きを決める（AeroSpace の `default-root-container-orientation = auto` 相当）。
    public static func automatic(for size: CGSize) -> Orientation {
        size.width >= size.height ? .horizontal : .vertical
    }
}

/// ルートコンテナの向きの決め方（設計書 §9.2 の `default-orientation`）。
public enum DefaultOrientation: String, Sendable, Equatable, CaseIterable {
    /// 領域の縦横比で決める。横長なら左右。
    case auto
    case horizontal
    case vertical

    public func resolve(for size: CGSize) -> Orientation {
        switch self {
        case .auto: .automatic(for: size)
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
    }
}

/// 画面上の四方向。コマンドの引数になる。
public enum Direction: String, Sendable, Equatable, CaseIterable {
    case left
    case down
    case up
    case right

    /// この方向が動かす軸。
    public var orientation: Orientation {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    /// 添字が増える向きか。AX 座標系では Y が下向きなので `down` が増加側。
    public var isForward: Bool {
        switch self {
        case .right, .down: true
        case .left, .up: false
        }
    }

    public var opposite: Direction {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }
}
