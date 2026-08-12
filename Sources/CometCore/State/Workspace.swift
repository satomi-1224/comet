import CoreGraphics

public typealias WorkspaceID = Int

/// ワークスペース1つ分。**タイル配置のルートはワークスペースごとに持つ。**
///
/// 実現方式は**画面外退避**。macOS ネイティブの Spaces は常に1つだけ使い、
/// 非表示ワークスペースのウィンドウは全モニタの外側へ動かす。SIP を無効化せずに済み、
/// 切替に OS のアニメーションが挟まらない。
public final class Workspace {

    public let id: WorkspaceID

    /// タイル配置のルート。空でも常に存在する。
    public let root: ContainerNode

    /// このワークスペースを離れる直前にフォーカスしていたウィンドウ。
    ///
    /// 戻ってきたときにここへフォーカスを返す。無ければ先頭のウィンドウ。
    public var lastFocused: CGWindowID?

    /// レイアウトが変化しており、復帰時にサイズの再適用が必要か。
    ///
    /// **非アクティブ中に何も起きていなければ、復帰時は位置の設定だけで済む。**
    /// AX には位置とサイズを一括設定する API が無いので、サイズを省くと
    /// 1ウィンドウあたりの IPC が2回から1回に減る（症状C の対策のひとつ）。
    ///
    /// 生成直後は「まだ一度も配置していない」ので `true`。
    public var isLayoutDirty = true

    /// 領域いっぱいに広げているウィンドウ（`fullscreen` コマンド）。
    ///
    /// **ワークスペースごとに1枚だけ。** 他のウィンドウは後ろに残したままにするので、
    /// 解除は「この値を捨てて再配置する」だけで済む。
    public var fullscreenWindowID: CGWindowID?

    public init(id: WorkspaceID, orientation: Orientation = .horizontal) {
        self.id = id
        self.root = ContainerNode(orientation: orientation)
    }
}

/// ワークスペースの集合と、今どれが見えているか。
///
/// **ウィンドウがどのワークスペースに属するかは持たない。** それは台帳
/// （``WindowRegistry``）側の情報で、ここのツリーは台帳から ``TreeSync`` で導出される。
/// 二箇所で持つと必ずずれる。
public final class WorkspaceManager {

    public let count: Int
    public private(set) var activeID: WorkspaceID
    /// 直前に見ていたワークスペース。`workspace back-and-forth` で戻る先。
    public private(set) var previousID: WorkspaceID?

    private var workspaces: [WorkspaceID: Workspace]

    public init(count: Int = 10, active: WorkspaceID = 1) {
        // 0 個だと有効なワークスペースが存在しなくなる。
        let resolved = max(1, count)
        self.count = resolved
        self.workspaces = Dictionary(
            uniqueKeysWithValues: (1...resolved).map { ($0, Workspace(id: $0)) })
        self.activeID = (1...resolved).contains(active) ? active : 1
    }

    public subscript(id: WorkspaceID) -> Workspace? {
        workspaces[id]
    }

    /// 今見えているワークスペース。
    ///
    /// `activeID` は常に範囲内に保たれるので、ここが `nil` になることはない。
    public var active: Workspace {
        // 到達不能。保険として1番を返す（常駐プロセスを落とさない）。
        workspaces[activeID] ?? workspaces[1]!
    }

    /// ID 昇順。
    public var all: [Workspace] {
        (1...count).compactMap { workspaces[$0] }
    }

    // MARK: - 切替

    /// 切り替える。
    ///
    /// - Returns: 切り替わったか。同じ ID や範囲外なら `false`。
    @discardableResult
    public func activate(_ id: WorkspaceID) -> Bool {
        guard workspaces[id] != nil, id != activeID else { return false }
        previousID = activeID
        activeID = id
        return true
    }

    /// 直前のワークスペースへ戻る。続けて呼ぶと2つの間を往復する。
    @discardableResult
    public func activatePrevious() -> Bool {
        guard let previousID else { return false }
        return activate(previousID)
    }

    // MARK: - レイアウトの変更フラグ

    /// 全ワークスペースにサイズ再適用を要求する。
    ///
    /// モニタ構成や gaps が変わったときは、非表示側も含めて寸法が合わなくなる。
    public func markAllLayoutsDirty() {
        for workspace in workspaces.values {
            workspace.isLayoutDirty = true
        }
    }
}
