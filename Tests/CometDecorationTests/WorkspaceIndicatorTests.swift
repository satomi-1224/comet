import Testing
import CometCore
@testable import CometDecoration

/// メニューバーに並べるもの。**i3 のバーと同じ考え方。**
///
/// 出すのは「映っている」か「ウィンドウが居る」番号だけ。空の番号まで並べると
/// 押す手掛かりにならないうえ、10 個並んでメニューバーを埋める。
@Suite("ワークスペースのインジケータ")
struct WorkspaceIndicatorTests {

    private func status(
        visible: [(MonitorID, WorkspaceID)], focused: WorkspaceID, occupied: Set<WorkspaceID>,
        total: Int = 10
    ) -> WorkspaceStatus {
        WorkspaceStatus(
            visible: visible.map { MonitorAssignment(monitor: $0.0, workspace: $0.1) },
            focused: focused, occupied: occupied, total: total)
    }

    @Test("1画面ならフォーカス中と中身のある番号を並べる")
    func singleMonitor() {
        let segments = WorkspaceIndicator.segments(
            status(visible: [(1, 1)], focused: 1, occupied: [1, 3, 5]))
        #expect(segments.map(\.workspace) == [1, 3, 5])
        #expect(segments[0].emphasis == .focused)
        #expect(segments[1].emphasis == .occupied)
        #expect(WorkspaceIndicator.plainTitle(segments) == "[1] 3 5")
    }

    @Test("2画面では別の画面に映っているものを区別する")
    func twoMonitors() {
        let segments = WorkspaceIndicator.segments(
            status(visible: [(1, 1), (2, 2)], focused: 2, occupied: [1, 2, 7]))
        #expect(WorkspaceIndicator.plainTitle(segments) == "(1) [2] 7")
    }

    // 空のワークスペースを映しているときは、その番号だけは出す。
    // 「今どこにいるか」が消えると切替の合図にならない。
    @Test("空でも映っている番号は出す")
    func visibleEmptyWorkspaceIsListed() {
        let segments = WorkspaceIndicator.segments(
            status(visible: [(1, 4)], focused: 4, occupied: [1]))
        #expect(segments.map(\.workspace) == [1, 4])
        #expect(WorkspaceIndicator.plainTitle(segments) == "1 [4]")
    }

    @Test("番号順に並ぶ")
    func sortedByNumber() {
        let segments = WorkspaceIndicator.segments(
            status(visible: [(1, 9)], focused: 9, occupied: [10, 2, 9]))
        #expect(segments.map(\.workspace) == [2, 9, 10])
    }

    // 名前を全部に添えると横に長くなり、切り替えるたびに位置が動いて読みにくい。
    @Test("名前は今いるワークスペースにだけ添える")
    func nameIsOnlyOnTheFocusedOne() {
        let segments = WorkspaceIndicator.segments(
            status(visible: [(1, 1)], focused: 1, occupied: [1, 2]),
            names: [1: "web", 2: "code"])
        #expect(segments[0].text == "1:web")
        #expect(segments[1].text == "2")
    }

    @Test("空の名前は添えない")
    func emptyNameIsIgnored() {
        let segments = WorkspaceIndicator.segments(
            status(visible: [(1, 1)], focused: 1, occupied: [1]), names: [1: ""])
        #expect(segments[0].text == "1")
    }

    @Test("フォーカスしているモニタを引ける")
    func focusedMonitorIsResolved() {
        let value = status(visible: [(11, 1), (22, 2)], focused: 2, occupied: [])
        #expect(value.focusedMonitor == 22)
        // 映っていない番号にフォーカスがある状態は作らないが、落ちないこと。
        #expect(status(visible: [], focused: 3, occupied: []).focusedMonitor == nil)
    }

    @Test("ウィンドウが1枚も無ければ映っている番号だけ")
    func emptyEverywhere() {
        let segments = WorkspaceIndicator.segments(
            status(visible: [(1, 1)], focused: 1, occupied: []))
        #expect(WorkspaceIndicator.plainTitle(segments) == "[1]")
    }
}
