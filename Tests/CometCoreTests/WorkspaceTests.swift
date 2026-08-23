import CoreGraphics
import Testing

@testable import CometCore

/// ワークスペース。**画面外退避方式**で実現する。
///
/// macOS ネイティブの Spaces は常に1つだけ使い、非表示ワークスペースのウィンドウは
/// 全モニタの外側へ動かす。SIP を無効化せずに済み、切替に OS のアニメーションが挟まらない。
@Suite("Workspace")
struct WorkspaceTests {

    // MARK: - 構成

    @Test("既定で 10 個を持ち、1 が有効")
    func defaultConfiguration() {
        let manager = WorkspaceManager()
        #expect(manager.count == 10)
        #expect(manager.activeID == 1)
        #expect(manager.active.id == 1)
        #expect(manager.previousID == nil)
        #expect(manager.all.map(\.id) == Array(1...10))
    }

    @Test("個数を指定できる")
    func customCount() {
        let manager = WorkspaceManager(count: 4)
        #expect(manager.all.map(\.id) == [1, 2, 3, 4])
    }

    // 0 個だと active が存在しなくなる。1 個までは切り下げる。
    @Test("個数は 1 未満にならない")
    func countIsAtLeastOne() {
        #expect(WorkspaceManager(count: 0).count == 1)
        #expect(WorkspaceManager(count: -5).count == 1)
    }

    @Test("範囲外の ID は引けない")
    func outOfRangeLookup() {
        let manager = WorkspaceManager(count: 3)
        #expect(manager[1] != nil)
        #expect(manager[3] != nil)
        #expect(manager[0] == nil)
        #expect(manager[4] == nil)
    }

    @Test("有効なワークスペースが範囲外なら 1 に落とす")
    func invalidInitialActiveFallsBack() {
        #expect(WorkspaceManager(count: 3, active: 99).activeID == 1)
        #expect(WorkspaceManager(count: 3, active: 0).activeID == 1)
    }

    @Test("ワークスペースごとに別のツリーを持つ")
    func eachWorkspaceHasItsOwnTree() {
        let manager = WorkspaceManager(count: 2)
        manager[1]?.root.append(WindowNode(10))
        manager[2]?.root.append(WindowNode(20))

        #expect(manager[1]?.root.windowIDs == [10])
        #expect(manager[2]?.root.windowIDs == [20])
        #expect(manager[1]?.root !== manager[2]?.root)
    }

    // MARK: - 切替（1画面）

    @Test("切り替えると直前のワークスペースを覚える")
    func activateRemembersPrevious() {
        let manager = WorkspaceManager()
        #expect(manager.activate(3) == .replaced(monitor: 0, outgoing: 1))

        #expect(manager.activeID == 3)
        #expect(manager.previousID == 1)
    }

    @Test("同じワークスペースへの切り替えは何もしない")
    func activatingTheSameWorkspaceIsNoop() {
        let manager = WorkspaceManager()
        #expect(manager.activate(1) == .alreadyActive)
        #expect(manager.previousID == nil, "直前を上書きしない")
    }

    @Test("範囲外への切り替えは拒否する")
    func activatingOutOfRangeIsRejected() {
        let manager = WorkspaceManager(count: 3)
        #expect(manager.activate(9) == .unknown)
        #expect(manager.activeID == 1)
        #expect(manager.previousID == nil)
    }

    @Test("back-and-forth は直前へ戻る")
    func backAndForthReturnsToPrevious() {
        let manager = WorkspaceManager()
        manager.activate(5)
        let previous = try! #require(manager.previousID)
        #expect(!manager.activate(previous).isNoop)
        #expect(manager.activeID == 1)
        #expect(manager.previousID == 5)
    }

    @Test("back-and-forth を続けると2つの間を往復する")
    func backAndForthTogglesBetweenTwo() {
        let manager = WorkspaceManager()
        manager.activate(7)
        for expected in [1, 7, 1] {
            manager.activate(manager.previousID!)
            #expect(manager.activeID == expected)
        }
    }

    // MARK: - 切替（2画面）

    /// **既に別のモニタに映っているならフォーカスを移すだけ。**
    /// ウィンドウを動かすと、そのモニタで作業していた配置が壊れる（i3 と同じ）。
    @Test("別のモニタに映っているワークスペースへはフォーカスだけ移す")
    func switchingToAWorkspaceOnAnotherMonitorJustFocusesIt() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22])
        #expect(manager.shown(on: 11) == 1)
        #expect(manager.shown(on: 22) == 2)
        #expect(manager.focusedMonitor == 11)

        #expect(manager.activate(2) == .focusedOtherMonitor(22))
        #expect(manager.focusedMonitor == 22)
        #expect(manager.activeID == 2)
        // 映っている組み合わせは変わらない。
        #expect(manager.shown(on: 11) == 1)
        #expect(manager.shown(on: 22) == 2)
    }

    @Test("映っていないワークスペースは今のモニタに映す")
    func switchingToAHiddenWorkspaceReplacesTheCurrentOne() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22])

        #expect(manager.activate(3) == .replaced(monitor: 11, outgoing: 1))
        #expect(manager.shown(on: 11) == 3)
        #expect(manager.shown(on: 22) == 2, "もう一方は動かさない")
        #expect(manager.visibleIDs == [3, 2])
        #expect(!manager.isVisible(1))
    }

    @Test("モニタごとに違う番号を配る")
    func eachMonitorGetsADistinctWorkspace() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22, 33])
        #expect(Set([11, 22, 33].compactMap { manager.shown(on: $0) }).count == 3)
    }

    /// **消えたモニタの割り当ては外す。** 外さないと「どのモニタにも映っていないのに
    /// 退避もされない」ウィンドウが画面に残る。
    @Test("モニタが減ったら割り当てを外す")
    func removingAMonitorDropsItsAssignment() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22])
        manager.focusMonitor(22)

        manager.reassign(monitors: [11])
        #expect(manager.shown(on: 22) == nil)
        #expect(manager.focusedMonitor == 11, "消えたモニタにフォーカスを残さない")
        #expect(manager.visibleIDs == [1])
    }

    @Test("並び順で隣のモニタへ。端では巻き戻る")
    func monitorSteppingWraps() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22, 33])
        #expect(manager.monitor(offsetFrom: 11, by: 1) == 22)
        #expect(manager.monitor(offsetFrom: 33, by: 1) == 11)
        #expect(manager.monitor(offsetFrom: 11, by: -1) == 33)
    }

    /// 相手が映していたワークスペースは入れ替わりにこちらへ来る。
    /// 片方が空になるより、両方が何かを映しているほうが分かりやすい。
    @Test("ワークスペースをモニタ間で入れ替えられる")
    func workspacesSwapBetweenMonitors() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22])

        #expect(manager.moveActiveWorkspace(to: 22))
        #expect(manager.shown(on: 22) == 1)
        #expect(manager.shown(on: 11) == 2)
        #expect(manager.focusedMonitor == 22, "フォーカスはワークスペースについていく")
        #expect(manager.activeID == 1)
    }

    @Test("同じモニタへの移動は何もしない")
    func movingToTheSameMonitorIsNoop() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22])
        #expect(!manager.moveActiveWorkspace(to: 11))
        #expect(!manager.moveActiveWorkspace(to: 99))
    }

    // MARK: - レイアウトの変更フラグ

    // 非アクティブ中に何も起きていなければ、復帰時は位置の設定だけで済む。
    // サイズの設定を省くと1ウィンドウあたりの IPC が2回から1回に減る（症状C対策）。
    @Test("生成直後は要サイズ再適用")
    func freshWorkspaceNeedsResize() {
        #expect(WorkspaceManager()[1]?.isLayoutDirty == true)
    }

    @Test("変更フラグを一括で立てられる")
    func markAllDirty() {
        let manager = WorkspaceManager(count: 3)
        for workspace in manager.all {
            workspace.isLayoutDirty = false
        }
        manager.markAllLayoutsDirty()
        let allDirty = manager.all.allSatisfy(\.isLayoutDirty)
        #expect(allDirty)
    }

    @Test("フォーカスを保存して取り出せる")
    func lastFocusedRoundTrip() {
        let manager = WorkspaceManager()
        manager.active.lastFocused = 42
        manager.activate(2)
        #expect(manager[1]?.lastFocused == 42)
        #expect(manager[2]?.lastFocused == nil)
    }

    // MARK: - 画面に出ている組み合わせ

    @Test("表示中の組はモニタの並び順で返る")
    func visiblePairsFollowMonitorOrder() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22])
        let pairs = manager.visiblePairs
        #expect(pairs.map(\.monitor) == [11, 22])
        #expect(pairs.map(\.workspace.id) == [1, 2])
    }

    @Test("そのワークスペースを映しているモニタを引ける")
    func monitorShowingAWorkspace() {
        let manager = WorkspaceManager(count: 4)
        manager.reassign(monitors: [11, 22])
        #expect(manager.monitor(showing: 2) == 22)
        #expect(manager.monitor(showing: 4) == nil)
    }

    // MARK: - 退避座標

    @Test("退避先は全モニタの外側になる")
    func stashOriginIsOutsideAllMonitors() {
        let monitors = [
            CGRect(x: 0, y: 0, width: 2560, height: 1664),
            CGRect(x: 2560, y: 0, width: 1920, height: 1080),
        ]
        let origin = Geometry.stashOrigin(outside: monitors, margin: 100_000)

        // #expect の中で整数式と CGFloat を比べると常に不一致になる。両辺を揃える。
        #expect(origin.y == CGFloat(101_664))
        // x は「1pt だけ重ねる」位置。完全に外へ出すと引き戻されて 40pt 残る（実測）。
        #expect(origin.x == CGFloat(4479), "union の右端から 1pt 内側")
    }

    // 負の方向へ逃がすとアプリ側で画面内へ引き戻されることがある。
    @Test("退避先は正方向へ逃がす")
    func stashOriginGoesPositive() {
        let above = [CGRect(x: 0, y: -2000, width: 1000, height: 1000)]
        #expect(Geometry.stashOrigin(outside: above, margin: 100_000).y > 0)
    }

    @Test("モニタが無くても退避先を返す")
    func stashOriginWithoutMonitors() {
        let origin = Geometry.stashOrigin(outside: [], margin: 100_000)
        #expect(origin.y >= 100_000)
    }

    // 寸法 0 のモニタ矩形は「その位置に画面がある」ことを意味しない。
    // union に混ぜると退避先が無意味に遠ざかる。
    @Test("空の矩形は union に含めない")
    func stashOriginIgnoresEmptyRects() {
        let origin = Geometry.stashOrigin(
            outside: [
                CGRect(x: 0, y: 9000, width: 0, height: 0),
                CGRect(x: 0, y: 0, width: 100, height: 500),
            ], margin: 1000)
        #expect(origin.y == 1500)
        #expect(origin.x == 99, "右端 100 の 1pt 内側")
    }
}

/// `workspace next` / `prev` の行き先。
///
/// **i3 は「存在するワークスペース」を巡る。** comet の番号は 1〜N で常に存在するので、
/// 空のものを飛ばすことで同じ動きにする。飛ばさないと、10 個のうち3個しか使って
/// いないときに空の画面を何度も通過することになる。
@Suite("中身のあるワークスペースを巡る")
struct OccupiedWorkspaceStepTests {

    @Test("空のワークスペースを飛ばす")
    func skipsEmptyWorkspaces() {
        let manager = WorkspaceManager(count: 10)
        manager.reassign(monitors: [1])
        #expect(manager.occupiedID(offsetFrom: 1, by: 1, occupied: [1, 5]) == 5)
        #expect(manager.occupiedID(offsetFrom: 5, by: 1, occupied: [1, 5]) == 1, "端では巻き戻る")
        #expect(manager.occupiedID(offsetFrom: 1, by: -1, occupied: [1, 5]) == 5)
    }

    @Test("今いる場所は空でも候補に入る")
    func theCurrentWorkspaceIsAlwaysACandidate() {
        let manager = WorkspaceManager(count: 10)
        manager.reassign(monitors: [1])
        manager.activate(4)
        #expect(manager.occupiedID(offsetFrom: 4, by: 1, occupied: [7]) == 7)
        #expect(manager.occupiedID(offsetFrom: 7, by: 1, occupied: [7]) == 4, "戻って来られる")
    }

    // 2画面では相手側のワークスペースが空でも渡れないと困る。
    @Test("映っているワークスペースは空でも候補に入る")
    func visibleWorkspacesAreCandidates() {
        let manager = WorkspaceManager(count: 10)
        manager.reassign(monitors: [1, 2])
        #expect(manager.visibleIDs.count == 2)
        let ids = manager.visibleIDs.sorted()
        #expect(manager.occupiedID(offsetFrom: ids[0], by: 1, occupied: []) == ids[1])
    }

    @Test("他に行き先が無ければ nil")
    func noDestinationReturnsNil() {
        let manager = WorkspaceManager(count: 1)
        manager.reassign(monitors: [1])
        #expect(manager.occupiedID(offsetFrom: 1, by: 1, occupied: [1]) == nil)
    }

    @Test("番号順の移動はこれまでどおり空も通る")
    func numericStepIsUnchanged() {
        let manager = WorkspaceManager(count: 3)
        #expect(manager.id(offsetFrom: 1, by: 1) == 2)
        #expect(manager.id(offsetFrom: 3, by: 1) == 1)
    }
}
