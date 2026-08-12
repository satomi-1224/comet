import CoreGraphics

/// 枠線を描く対象。
///
/// 矩形だけでなく **ID も渡す**。矩形は「どこに描くか」しか決められず、
/// 「今それが見えているか」（Mission Control・別 Space・Cmd+H）は
/// ID が無いと確かめられない（``WindowVisibility``）。
public struct FocusedWindow: Equatable, Sendable {
    public let id: CGWindowID
    /// AX 座標（左上原点）での矩形。
    public let frame: CGRect

    public init(id: CGWindowID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}
