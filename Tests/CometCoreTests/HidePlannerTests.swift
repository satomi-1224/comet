import CoreGraphics
import Darwin
import Testing

@testable import CometCore

/// アプリ単位の非表示（Cmd+H 相当）で非表示ワークスペースを隠す判定。
///
/// **判定を誤ると見ているワークスペースのウィンドウまで消える。** アプリ単位という
/// 粒度がそのまま危険なので、ここは境界を全部押さえておく。
@Suite("HidePlanner")
struct HidePlannerTests {

    private func window(_ id: CGWindowID, pid: pid_t, workspace: WorkspaceID) -> HidePlanner.Window
    {
        HidePlanner.Window(id: id, pid: pid, workspace: workspace)
    }

    private func plan(
        _ windows: [HidePlanner.Window],
        active: WorkspaceID = 1,
        hidden: Set<pid_t> = [],
        strategy: HiddenWindowStrategy = .hideApp
    ) -> HidePlanner.Plan {
        HidePlanner.plan(
            windows: windows, activeWorkspace: active, hiddenApps: hidden, strategy: strategy)
    }

    // MARK: - アプリごと隠せる場合

    @Test("全ウィンドウが非表示ワークスペースならアプリごと隠す")
    func hidesAppWhenAllWindowsAreHidden() {
        let result = plan([window(1, pid: 100, workspace: 2), window(2, pid: 100, workspace: 3)])

        #expect(result.hide == [100])
        #expect(result.stash.isEmpty, "アプリごと隠せるなら個別の隅寄せは不要")
        #expect(result.unhide.isEmpty)
    }

    @Test("すでに隠れているアプリには何もしない")
    func alreadyHiddenAppIsLeftAlone() {
        let result = plan([window(1, pid: 100, workspace: 2)], hidden: [100])
        #expect(result.isEmpty)
    }

    // MARK: - 隠せない場合

    // ここを誤ると「見ているワークスペースのウィンドウが消える」最悪の壊れ方になる。
    @Test("表示中のウィンドウを持つアプリは絶対に隠さない")
    func neverHidesAppWithVisibleWindow() {
        let result = plan([window(1, pid: 100, workspace: 1), window(2, pid: 100, workspace: 2)])

        #expect(result.hide.isEmpty)
        #expect(result.stash == [2], "隠れている側だけ隅へ寄せる")
    }

    @Test("表示すべきウィンドウが出てきたらアプリを表示へ戻す")
    func unhidesAppWhenAWindowBecomesVisible() {
        let result = plan(
            [window(1, pid: 100, workspace: 1), window(2, pid: 100, workspace: 2)], hidden: [100])

        #expect(result.unhide == [100])
        #expect(result.stash == [2])
    }

    @Test("表示中のウィンドウしか無いアプリは隠しも隅寄せもしない")
    func fullyVisibleAppIsUntouched() {
        let result = plan([window(1, pid: 100, workspace: 1)])
        #expect(result.isEmpty)
    }

    @Test("表示中しか無くて隠れているアプリは戻すだけ")
    func hiddenAppWithOnlyVisibleWindowsIsRestored() {
        let result = plan([window(1, pid: 100, workspace: 1)], hidden: [100])
        #expect(result.unhide == [100])
        #expect(result.stash.isEmpty)
    }

    // MARK: - 隅寄せ方式

    @Test("off-screen 指定ならアプリを隠さない")
    func offScreenStrategyNeverHides() {
        let result = plan(
            [window(1, pid: 100, workspace: 2), window(2, pid: 100, workspace: 3)],
            strategy: .offScreen)

        #expect(result.hide.isEmpty)
        #expect(result.stash == [1, 2])
    }

    // 方式を切り替えたときに隠れっぱなしにならないこと。
    @Test("off-screen 指定でも隠れているアプリは戻す")
    func offScreenStrategyRestoresHiddenApps() {
        let result = plan(
            [window(1, pid: 100, workspace: 2)], hidden: [100], strategy: .offScreen)

        #expect(result.unhide == [100])
        #expect(result.stash == [1])
    }

    // MARK: - 複数アプリ

    @Test("アプリごとに独立して判定する")
    func decidesPerApplication() {
        let result = plan([
            // 100: 全部隠れている → アプリごと隠す
            window(1, pid: 100, workspace: 2),
            // 200: 混在 → 隅寄せ
            window(2, pid: 200, workspace: 1),
            window(3, pid: 200, workspace: 3),
            // 300: 全部見えている → 何もしない
            window(4, pid: 300, workspace: 1),
        ])

        #expect(result.hide == [100])
        #expect(result.stash == [3])
        #expect(result.unhide.isEmpty)
    }

    @Test("並びは入力順で決定的")
    func orderIsDeterministic() {
        let windows = [
            window(1, pid: 300, workspace: 2),
            window(2, pid: 100, workspace: 2),
            window(3, pid: 200, workspace: 2),
        ]
        #expect(plan(windows).hide == [300, 100, 200])
        #expect(plan(windows).hide == plan(windows).hide)
    }

    @Test("ウィンドウが無ければ何もしない")
    func emptyInput() {
        #expect(plan([]).isEmpty)
    }

    // MARK: - 有効なワークスペースの扱い

    @Test("有効なワークスペースが変われば判定も変わる")
    func activeWorkspaceDecidesEverything() {
        let windows = [window(1, pid: 100, workspace: 1), window(2, pid: 200, workspace: 2)]

        let onOne = plan(windows, active: 1)
        #expect(onOne.hide == [200])

        let onTwo = plan(windows, active: 2)
        #expect(onTwo.hide == [100])
    }

    @Test("どのワークスペースにも表示対象が無ければ全アプリを隠す")
    func hidesEverythingOnAnEmptyWorkspace() {
        let result = plan(
            [window(1, pid: 100, workspace: 2), window(2, pid: 200, workspace: 3)], active: 9)

        #expect(Set(result.hide) == [100, 200])
        #expect(result.stash.isEmpty)
    }
}
