import CoreGraphics

/// AX の role 定数。
///
/// SDK 側は `CFSTR` マクロや可変グローバルとして宣言されており Swift から扱いにくいため、
/// 値を直接持つ。これらは長期に安定した公開仕様。
public enum AXRole {
    public static let window = "AXWindow"
}

/// AX の subrole 定数。
public enum AXSubrole {
    public static let standardWindow = "AXStandardWindow"
    public static let dialog = "AXDialog"
    public static let systemDialog = "AXSystemDialog"
    public static let floatingWindow = "AXFloatingWindow"
    public static let systemFloatingWindow = "AXSystemFloatingWindow"
}

/// 判定に必要な属性だけを抜き出したもの。
///
/// AX から `AXUIElementCopyMultipleAttributeValues` で**1往復**にまとめて取得する。
/// 判定自体を純粋関数にしておくことで、AX 抜きでテストできる。
public struct WindowSnapshot: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var isFullScreen: Bool
    public var isMinimized: Bool
    public var size: CGSize

    public init(
        role: String?,
        subrole: String?,
        isFullScreen: Bool = false,
        isMinimized: Bool = false,
        size: CGSize
    ) {
        self.role = role
        self.subrole = subrole
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
        self.size = size
    }
}

/// タイル管理から外す理由。
public enum UnmanagedReason: String, Equatable, Sendable, CaseIterable, CustomStringConvertible {
    case unknownRole
    case notAWindow
    case nonStandardSubrole
    case fullScreen
    case minimized
    case tooSmall

    /// 状態の変化で解消しうるか。
    ///
    /// 一時的なものは通知を受けて再評価する。恒久的なものは判定を保持してよく、
    /// 毎回 AX を叩かずに済む。
    public var isTransient: Bool {
        switch self {
        case .fullScreen, .minimized, .tooSmall: true
        case .unknownRole, .notAWindow, .nonStandardSubrole: false
        }
    }

    public var description: String {
        switch self {
        case .unknownRole: "role を取得できない"
        case .notAWindow: "role が AXWindow ではない"
        case .nonStandardSubrole: "subrole が AXStandardWindow ではない"
        case .fullScreen: "ネイティブフルスクリーン"
        case .minimized: "最小化されている"
        case .tooSmall: "小さすぎる"
        }
    }
}

public enum WindowDisposition: Equatable, Sendable {
    case tiled
    case unmanaged(UnmanagedReason)

    public var isTiled: Bool { self == .tiled }
}

/// どのウィンドウをタイル管理下に置くかの判定。
///
/// 誤って管理下に入れるとダイアログやポップオーバーが勝手にリサイズされてアプリが壊れて見える。
/// 逆に落としすぎると普通のウィンドウが並ばない。
public enum WindowClassifier {

    /// これ未満のウィンドウは管理しない。
    /// ツールパレットや隠しウィンドウを掴まないための下限。
    public static let minimumSize = CGSize(width: 40, height: 40)

    /// 判定の順序は診断の質に効く。
    /// **素性の問題（恒久的）を一時的な状態より先に報告する。**
    /// ダイアログが最小化されているときに「最小化」と報告すると、
    /// 復帰すればタイル対象になると誤解させる。
    public static func classify(
        _ snapshot: WindowSnapshot,
        minimumSize: CGSize = minimumSize
    ) -> WindowDisposition {
        guard let role = snapshot.role else {
            return .unmanaged(.unknownRole)
        }
        guard role == AXRole.window else {
            return .unmanaged(.notAWindow)
        }
        // subrole を返さないウィンドウは素性が分からない。
        // 誤ってダイアログを掴むより落とす方が害が小さい。
        guard snapshot.subrole == AXSubrole.standardWindow else {
            return .unmanaged(.nonStandardSubrole)
        }
        // ネイティブフルスクリーンは独自の Space を作るため、
        // 画面外退避方式のワークスペースと根本的に衝突する。
        if snapshot.isFullScreen {
            return .unmanaged(.fullScreen)
        }
        if snapshot.isMinimized {
            return .unmanaged(.minimized)
        }
        if snapshot.size.width < minimumSize.width || snapshot.size.height < minimumSize.height {
            return .unmanaged(.tooSmall)
        }
        return .tiled
    }
}
