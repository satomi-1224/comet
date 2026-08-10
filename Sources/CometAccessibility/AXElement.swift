import ApplicationServices
import CoreGraphics
import Darwin

/// `AXUIElement` を並行境界を越えて運ぶための箱。
///
/// `AXUIElement` は CoreFoundation の不変オブジェクトでスレッド間の受け渡しは安全だが、
/// Swift 6 では `Sendable` に適合していないためそのままでは PID キューへ渡せない。
///
/// - Important: 箱に入れても**メインスレッドで AX API を呼んでよいことにはならない**。
///   AX 呼び出しは対象アプリとの同期 IPC であり、必ず PID ごとのキュー上で行うこと。
public struct AXElement: @unchecked Sendable, Hashable {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) {
        self.raw = raw
    }

    public static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        CFEqual(lhs.raw, rhs.raw)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(raw))
    }

    /// 要素の所属プロセス。
    public var pid: pid_t? {
        var value: pid_t = 0
        guard AXUIElementGetPid(raw, &value) == .success, value > 0 else { return nil }
        return value
    }
}

/// AX 属性名。
///
/// SDK 側は `CFSTR` マクロで定義されており Swift から安定して参照できないため値を持つ。
/// いずれも長期に安定した公開仕様。
public enum AXAttribute {
    public static let role = "AXRole"
    public static let subrole = "AXSubrole"
    public static let title = "AXTitle"
    public static let position = "AXPosition"
    public static let size = "AXSize"
    public static let minimized = "AXMinimized"
    public static let fullScreen = "AXFullScreen"
    public static let windows = "AXWindows"
    public static let focusedWindow = "AXFocusedWindow"
    public static let main = "AXMain"
    public static let focused = "AXFocused"
    public static let closeButton = "AXCloseButton"
    /// 支援技術向けの非公開属性。有効なアプリではウィンドウ操作が遅くなる。
    public static let enhancedUserInterface = "AXEnhancedUserInterface"
}

/// AX アクション名。
public enum AXAction {
    public static let raise = "AXRaise"
    public static let press = "AXPress"
}

/// AX 通知名。
public enum AXNotification {
    public static let windowCreated = "AXWindowCreated"
    public static let uiElementDestroyed = "AXUIElementDestroyed"
    public static let focusedWindowChanged = "AXFocusedWindowChanged"
    public static let mainWindowChanged = "AXMainWindowChanged"
    public static let windowMoved = "AXWindowMoved"
    public static let windowResized = "AXWindowResized"
    public static let windowMiniaturized = "AXWindowMiniaturized"
    public static let windowDeminiaturized = "AXWindowDeminiaturized"
    public static let applicationActivated = "AXApplicationActivated"
}

/// ウィンドウから1往復で読み取った属性。
public struct AXWindowAttributes: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var position: CGPoint?
    public var size: CGSize?
    public var isMinimized: Bool
    public var isFullScreen: Bool

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        position: CGPoint? = nil,
        size: CGSize? = nil,
        isMinimized: Bool = false,
        isFullScreen: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.position = position
        self.size = size
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
    }

    /// 位置とサイズが揃っている場合の矩形（AX 座標系）。
    public var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }
}

/// 走査で見つかったウィンドウ1枚分。
public struct DiscoveredWindow: Sendable {
    public let id: CGWindowID
    public let element: AXElement
    public let attributes: AXWindowAttributes

    public init(id: CGWindowID, element: AXElement, attributes: AXWindowAttributes) {
        self.id = id
        self.element = element
        self.attributes = attributes
    }
}
