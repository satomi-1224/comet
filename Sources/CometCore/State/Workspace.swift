import CoreGraphics

public typealias WorkspaceID = Int
/// モニタの識別子。`CGDirectDisplayID` と同じ値だが、CoreGraphics を知らない層でも扱えるようにする。
public typealias MonitorID = UInt32

/// どのモニタがどのワークスペースを映しているか、1組ぶん。
public struct MonitorAssignment: Sendable, Equatable {
    public let monitor: MonitorID
    public let workspace: WorkspaceID

    public init(monitor: MonitorID, workspace: WorkspaceID) {
        self.monitor = monitor
        self.workspace = workspace
    }
}

/// 表示に必要なワークスペースの状態をまとめたもの。
///
/// **「今のワークスペース」1つでは足りない。** 2画面では複数が同時に見えているし、
/// i3 のバーと同じ見え方にするには「どの番号にウィンドウが居るか」も要る
///（居ない番号を並べても押す手掛かりにならない）。
public struct WorkspaceStatus: Sendable, Equatable {

    /// 画面に出ている組。**モニタの並び順**（左から右）。
    public let visible: [MonitorAssignment]
    /// 今フォーカスしているモニタのワークスペース。
    public let focused: WorkspaceID
    /// ウィンドウが1枚以上あるワークスペース。
    public let occupied: Set<WorkspaceID>
    /// ワークスペースの総数。
    public let total: Int

    public init(
        visible: [MonitorAssignment], focused: WorkspaceID, occupied: Set<WorkspaceID>, total: Int
    ) {
        self.visible = visible
        self.focused = focused
        self.occupied = occupied
        self.total = total
    }

    /// 今フォーカスしているモニタ。HUD をどの画面へ出すかを決める。
    public var focusedMonitor: MonitorID? {
        visible.first { $0.workspace == focused }?.monitor
    }
}

/// ワークスペース1つ分。**タイル配置のルートはワークスペースごとに持つ。**
///
/// 実現方式は**画面外退避**。macOS ネイティブの Spaces は常に1つだけ使い、
/// どのモニタにも映っていないワークスペースのウィンドウは全モニタの外側へ動かす。
/// SIP を無効化せずに済み、切替に OS のアニメーションが挟まらない。
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
    /// **非表示中に何も起きていなければ、復帰時は位置の設定だけで済む。**
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

/// ワークスペースの集合と、**どのモニタがどれを映しているか**。
///
/// ## モニタとワークスペースの関係（i3 の output と同じ考え方）
///
/// - **1つのモニタは常にちょうど1つのワークスペースを映す。**
/// - ワークスペースを指定したとき、それが既にどこかのモニタに映っていれば
///   **そのモニタへフォーカスを移すだけ**（ウィンドウは動かさない）。
/// - 映っていなければ、**今フォーカスしているモニタに映す**。
///   そのモニタが映していたワークスペースは非表示になる。
///
/// この規則にしておくと、2画面で `alt-1` `alt-2` を押したときの動きが i3 と一致する。
///
/// **ウィンドウがどのワークスペースに属するかは持たない。** それは台帳
/// （``WindowRegistry``）側の情報で、ここのツリーは台帳から ``TreeSync`` で導出される。
/// 二箇所で持つと必ずずれる。
public final class WorkspaceManager {

    public let count: Int

    /// 各モニタが映しているワークスペース。
    private var shownByMonitor: [MonitorID: WorkspaceID] = [:]
    /// フォーカスがあるモニタ。**必ず現在のモニタのどれかを指す。**
    public private(set) var focusedMonitor: MonitorID = 0
    /// 直前に見ていたワークスペース。`workspace back-and-forth` で戻る先。
    public private(set) var previousID: WorkspaceID?

    private var workspaces: [WorkspaceID: Workspace]

    public init(count: Int = 10, active: WorkspaceID = 1) {
        // 0 個だと有効なワークスペースが存在しなくなる。
        let resolved = max(1, count)
        self.count = resolved
        self.workspaces = Dictionary(
            uniqueKeysWithValues: (1...resolved).map { ($0, Workspace(id: $0)) })
        // モニタが分かるまでは 1台だけあるものとして扱う（ID 0 の仮のモニタ）。
        let start = (1...resolved).contains(active) ? active : 1
        self.shownByMonitor = [0: start]
    }

    public subscript(id: WorkspaceID) -> Workspace? {
        workspaces[id]
    }

    /// ID 昇順。
    public var all: [Workspace] {
        (1...count).compactMap { workspaces[$0] }
    }

    // MARK: - モニタ

    /// 今の全モニタ。**割り当てのあるものだけ**を、渡された順で返す。
    public private(set) var monitors: [MonitorID] = [0]

    /// モニタ構成に合わせて割り当てを直す。
    ///
    /// - 消えたモニタが映していたワークスペースは非表示になる（ウィンドウは退避される）。
    /// - 割り当ての無いモニタには、**まだどこにも映っていない最小の番号**を割り当てる。
    ///   足りなければ映せないままにはできないので、番号を共有せずに済む範囲で配る。
    ///
    /// - Parameter monitors: 並び順は左から右。`next` / `prev` はこの順に従う。
    /// - Returns: 割り当てが変わったか。
    @discardableResult
    public func reassign(monitors incoming: [MonitorID]) -> Bool {
        let resolved = incoming.isEmpty ? [0] : incoming
        let before = shownByMonitor
        monitors = resolved

        // 消えたモニタの割り当てを外す。
        shownByMonitor = shownByMonitor.filter { resolved.contains($0.key) }

        // 割り当ての無いモニタへ、まだ映っていない番号を配る。
        for monitor in resolved where shownByMonitor[monitor] == nil {
            let taken = Set(shownByMonitor.values)
            let free = (1...count).first { !taken.contains($0) }
            // 全部埋まっているなら（モニタ数 > ワークスペース数）1番を共有する。
            shownByMonitor[monitor] = free ?? 1
        }

        if !resolved.contains(focusedMonitor) {
            focusedMonitor = resolved[0]
        }
        return shownByMonitor != before
    }

    /// フォーカスするモニタを変える。
    ///
    /// - Returns: 変わったか。知らないモニタなら `false`。
    @discardableResult
    public func focusMonitor(_ monitor: MonitorID) -> Bool {
        guard monitors.contains(monitor), monitor != focusedMonitor else { return false }
        focusedMonitor = monitor
        return true
    }

    /// 並び順で隣のモニタ。**端では巻き戻る。**
    public func monitor(offsetFrom monitor: MonitorID, by offset: Int) -> MonitorID {
        guard let index = monitors.firstIndex(of: monitor), !monitors.isEmpty else {
            return monitors.first ?? 0
        }
        let count = monitors.count
        let next = ((index + offset) % count + count) % count
        return monitors[next]
    }

    /// そのモニタが映しているワークスペース。
    public func shown(on monitor: MonitorID) -> WorkspaceID? {
        shownByMonitor[monitor]
    }

    /// そのワークスペースを映しているモニタ。映っていなければ `nil`。
    public func monitor(showing id: WorkspaceID) -> MonitorID? {
        shownByMonitor.first { $0.value == id }?.key
    }

    /// 画面に出ているワークスペース。**退避の対象を決めるのはこれ。**
    public var visibleIDs: Set<WorkspaceID> {
        Set(shownByMonitor.values)
    }

    public func isVisible(_ id: WorkspaceID) -> Bool {
        shownByMonitor.values.contains(id)
    }

    /// 画面に出ている（モニタ, ワークスペース）の組。**モニタの並び順**で返す。
    public var visiblePairs: [(monitor: MonitorID, workspace: Workspace)] {
        monitors.compactMap { monitor in
            guard let id = shownByMonitor[monitor], let workspace = workspaces[id] else {
                return nil
            }
            return (monitor: monitor, workspace: workspace)
        }
    }

    // MARK: - 今フォーカスしているワークスペース

    /// フォーカスしているモニタが映しているワークスペースの ID。
    public var activeID: WorkspaceID {
        shownByMonitor[focusedMonitor] ?? shownByMonitor.values.min() ?? 1
    }

    /// フォーカスしているモニタが映しているワークスペース。
    public var active: Workspace {
        // 到達不能。保険として1番を返す（常駐プロセスを落とさない）。
        workspaces[activeID] ?? workspaces[1]!
    }

    // MARK: - 切替

    /// 指定のワークスペースへ切り替える。
    ///
    /// **既に別のモニタに映っているなら、そのモニタへフォーカスを移すだけ**
    /// （i3 と同じ。ウィンドウは動かさない）。映っていなければ、今のモニタに映す。
    ///
    /// - Returns: 何が起きたか。
    @discardableResult
    public func activate(_ id: WorkspaceID) -> Activation {
        guard workspaces[id] != nil else { return .unknown }
        if let monitor = monitor(showing: id) {
            guard monitor != focusedMonitor else { return .alreadyActive }
            let previous = activeID
            focusedMonitor = monitor
            previousID = previous
            return .focusedOtherMonitor(monitor)
        }
        let outgoing = activeID
        previousID = outgoing
        shownByMonitor[focusedMonitor] = id
        return .replaced(monitor: focusedMonitor, outgoing: outgoing)
    }

    public enum Activation: Equatable {
        /// そのワークスペースは存在しない。
        case unknown
        /// 既に今のモニタに映っている。
        case alreadyActive
        /// 別のモニタに映っていたので、そちらへフォーカスを移した。
        case focusedOtherMonitor(MonitorID)
        /// 今のモニタの表示を差し替えた。
        case replaced(monitor: MonitorID, outgoing: WorkspaceID)

        /// 画面の内容が変わったか（壁紙とインジケータを更新すべきか）。
        public var changedContents: Bool {
            if case .replaced = self { return true }
            return false
        }
        public var isNoop: Bool { self == .unknown || self == .alreadyActive }
    }

    /// ワークスペースを別のモニタへ移す（i3 の `move workspace to output`）。
    ///
    /// 相手のモニタが映していたワークスペースは、**入れ替わりにこちらへ来る**。
    /// 片方が空になるより、両方が何かを映しているほうが分かりやすい。
    ///
    /// - Returns: 入れ替えが起きたか。
    @discardableResult
    public func moveActiveWorkspace(to monitor: MonitorID) -> Bool {
        guard monitors.contains(monitor), monitor != focusedMonitor else { return false }
        let mine = activeID
        let theirs = shownByMonitor[monitor]
        shownByMonitor[monitor] = mine
        if let theirs {
            shownByMonitor[focusedMonitor] = theirs
        } else {
            shownByMonitor.removeValue(forKey: focusedMonitor)
        }
        // フォーカスは**ワークスペースについていく**。移したのに操作の対象が
        // 変わってしまうと、続けて打つコマンドの行き先が読めない。
        focusedMonitor = monitor
        return true
    }

    /// 番号順にずらした先の ID。**端では巻き戻る**（i3 の `workspace next` と同じ）。
    ///
    /// 巻き戻さないと、端まで来たときにキーが無反応になって「効いていない」と見える。
    public func id(offsetFrom id: WorkspaceID, by offset: Int) -> WorkspaceID {
        let zeroBased = ((id - 1 + offset) % count + count) % count
        return zeroBased + 1
    }

    /// **中身のあるワークスペースだけを順に辿った先。**
    ///
    /// i3 の `workspace next` は「存在するワークスペース」を巡る。comet の番号は
    /// 1〜N で常に存在するので、**空のものを飛ばす**ことで同じ動きにする。
    ///
    /// 飛ばさないと、10 個のうち3個しか使っていないときに空の画面を何度も
    /// 通過することになり、キーを何回押せば着くのかが読めない。
    /// 空のワークスペースへは番号を直に押して行く（i3 も同じ）。
    ///
    /// - Parameters:
    ///   - occupied: ウィンドウが1枚以上あるワークスペース。
    ///   - offset: `+1` で次、`-1` で前。
    /// - Returns: 行き先。候補が今いる場所しか無ければ `nil`。
    public func occupiedID(
        offsetFrom id: WorkspaceID, by offset: Int, occupied: Set<WorkspaceID>
    ) -> WorkspaceID? {
        // 今いる場所と映っているものは、空でも候補に入れる
        //（2画面で相手側へ渡れなくなるのを防ぐ）。
        var candidates = occupied.union(visibleIDs)
        candidates.insert(id)
        let ordered = candidates.filter { workspaces[$0] != nil }.sorted()
        guard ordered.count > 1, let index = ordered.firstIndex(of: id) else { return nil }
        let next = ((index + offset) % ordered.count + ordered.count) % ordered.count
        return ordered[next]
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
