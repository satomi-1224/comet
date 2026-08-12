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
    /// 重なりの階層（``WindowLayers``）。**分からないときは `nil`**。
    ///
    /// AX には無い情報で、ピクチャーインピクチャのような「常に手前へ出る窓」を
    /// 見分ける唯一の手がかりになる。
    public var layer: Int?

    public init(
        role: String?,
        subrole: String?,
        isFullScreen: Bool = false,
        isMinimized: Bool = false,
        size: CGSize,
        layer: Int? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
        self.size = size
        self.layer = layer
    }
}

/// タイル管理から外す理由。
public enum UnmanagedReason: String, Equatable, Sendable, CaseIterable, CustomStringConvertible {
    case unknownRole
    case notAWindow
    case nonStandardSubrole
    /// 常に手前へ出る窓（ピクチャーインピクチャ、常時最前面のパネル）。
    ///
    /// **AX 上はふつうのウィンドウに見える。** 見分けは `kCGWindowLayer` でしか付かない。
    case alwaysOnTop
    case fullScreen
    case minimized
    case tooSmall
    /// メインディスプレイの外（サブディスプレイの上）にある。
    ///
    /// **サブディスプレイは素の macOS のまま使えるようにする**ため、位置も大きさも触らない。
    case otherMonitor

    /// 状態の変化で解消しうるか。
    ///
    /// 一時的なものは通知を受けて再評価する。恒久的なものは判定を保持してよく、
    /// 毎回 AX を叩かずに済む。
    public var isTransient: Bool {
        switch self {
        // サブディスプレイ上は一時的な理由。メインへ戻したら再評価してタイルへ戻す。
        case .fullScreen, .minimized, .tooSmall, .otherMonitor: true
        // 階層は窓の素性であって状態ではない。ピクチャーインピクチャが
        // 普通のウィンドウに変わることはない。
        case .unknownRole, .notAWindow, .nonStandardSubrole, .alwaysOnTop: false
        }
    }

    public var description: String {
        switch self {
        case .unknownRole: "role を取得できない"
        case .notAWindow: "role が AXWindow ではない"
        case .nonStandardSubrole: "subrole が AXStandardWindow ではない"
        case .alwaysOnTop: "常に手前へ出る窓（ピクチャーインピクチャなど）"
        case .fullScreen: "ネイティブフルスクリーン"
        case .minimized: "最小化されている"
        case .tooSmall: "小さすぎる"
        case .otherMonitor: "メインディスプレイの外（サブディスプレイは制御しない）"
        }
    }
}

public enum WindowDisposition: Equatable, Sendable {
    case tiled
    /// ツリー外。位置は自由で、レイアウトは触らない。
    ///
    /// ウィンドウルールの `layout floating` 指定と `layout floating tiling` コマンドで
    /// この状態になる。判定（``WindowClassifier``）からは出てこない。
    case floating
    case unmanaged(UnmanagedReason)

    public var isTiled: Bool { self == .tiled }
    public var isFloating: Bool { self == .floating }
    /// サブディスプレイ上にあるため管理から外している状態か。
    public var isOnOtherMonitor: Bool { self == .unmanaged(.otherMonitor) }

    /// フォーカスの追跡対象にしてよいか。
    ///
    /// **ダイアログや拡張機能のポップアップを追ってはいけない。** これらはタイル対象から
    /// 外れていても台帳には載るため、追うと枠線がポップアップを囲み、以降のコマンドの
    /// 起点もそこになる（実際に Chrome の拡張機能パネルで起きた）。
    ///
    /// サブディスプレイのウィンドウは実在のアプリのウィンドウなので追う。
    public var acceptsFocusTracking: Bool { isTiled || isFloating || isOnOtherMonitor }

    /// 枠線を描いてよい状態か。
    ///
    /// **``acceptsFocusTracking`` とは別。** サブディスプレイのウィンドウは
    /// フォーカスは追うが枠線は描かない（あちらは素の macOS のまま使う場所）。
    /// ネイティブ全画面と最小化も、macOS 側が見た目を持っていくので描かない。
    public var showsFocusBorder: Bool { isTiled || isFloating }
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
        // **ピクチャーインピクチャはここで落ちる。** AX 上はふつうの
        // `AXStandardWindow` として見えるので、階層でしか見分けられない
        //（実測: 通常のウィンドウは 0、ピクチャーインピクチャは 3）。
        // 常に手前へ出る窓は並べる対象ではなく、フォーカスの巡回先でもない。
        //
        // **分からない（`nil`）ときは管理する。** 取得に失敗しただけで
        // 全ウィンドウが管理外になるほうが害が大きい。
        if let layer = snapshot.layer, layer != WindowLayers.normal {
            return .unmanaged(.alwaysOnTop)
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
