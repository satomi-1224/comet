import CoreGraphics
import Testing

@testable import CometCore

/// **メインディスプレイだけを制御し、サブディスプレイは素の macOS のままにする。**
///
/// comet はレイアウトをプライマリの `visibleFrame` に対してだけ計算する。
/// そのため何もしないと、サブディスプレイへ置いたウィンドウまでメインへ引き寄せてしまう
/// （外部からの移動は「レイアウトが唯一の正」として押し戻されるため）。
///
/// サブディスプレイ上のウィンドウは**管理対象から外す**ことで、
/// 自由に置ける・大きさも変えられる状態にする。
@Suite("サブディスプレイ")
struct SecondaryMonitorTests {

    /// 左に 2560x1440 のメイン、その右に 1920x1080 のサブがある構成。
    private let main = MonitorManager.Monitor(
        id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415), isPrimary: true, scale: 2)
    private let sub = MonitorManager.Monitor(
        id: 2, frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1080), isPrimary: false, scale: 1)

    private var monitors: [MonitorManager.Monitor] { [main, sub] }

    // MARK: - どのモニタのものか

    @Test("メインの上にあるウィンドウはメインのもの")
    func windowOnMain() {
        let rect = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(MonitorManager.owner(of: rect, among: monitors)?.id == main.id)
        #expect(!MonitorManager.isOutsideMain(rect, monitors: monitors))
    }

    @Test("サブの上にあるウィンドウはサブのもの")
    func windowOnSub() {
        let rect = CGRect(x: 2700, y: 100, width: 800, height: 600)
        #expect(MonitorManager.owner(of: rect, among: monitors)?.id == sub.id)
        #expect(MonitorManager.isOutsideMain(rect, monitors: monitors))
    }

    /// 2画面に跨がるウィンドウでも判定が一意になるように、**中心で決める。**
    /// 面積比で決めると境界付近で行き来して落ち着かない。
    @Test("跨がっているウィンドウは中心のあるほうのもの")
    func straddlingWindow() {
        // 中心が x=2500（メイン側）
        let onMain = CGRect(x: 2100, y: 100, width: 800, height: 600)
        #expect(MonitorManager.owner(of: onMain, among: monitors)?.id == main.id)
        // 中心が x=2620（サブ側）
        let onSub = CGRect(x: 2220, y: 100, width: 800, height: 600)
        #expect(MonitorManager.owner(of: onSub, among: monitors)?.id == sub.id)
    }

    // MARK: - 判断できないときは手放さない

    /// **どのモニタにも乗っていない矩形を「サブにある」と扱ってはいけない。**
    /// 非表示ワークスペースのウィンドウは画面の隅へ追い込まれており、中心が
    /// どのモニタからも外れる。これを管理対象から外すと**二度と戻せなくなる。**
    @Test("どのモニタにも乗っていなければ管理を続ける")
    func windowOutsideEveryMonitor() {
        let stashed = CGRect(x: 2559, y: 1418, width: 800, height: 600)
        #expect(MonitorManager.owner(of: stashed, among: monitors) == nil)
        #expect(!MonitorManager.isOutsideMain(stashed, monitors: monitors))
    }

    @Test("モニタ構成が分からなければ管理を続ける")
    func noMonitors() {
        let rect = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(MonitorManager.owner(of: rect, among: []) == nil)
        #expect(!MonitorManager.isOutsideMain(rect, monitors: []))
    }

    @Test("1画面なら常に管理対象")
    func singleMonitor() {
        let rect = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(!MonitorManager.isOutsideMain(rect, monitors: [main]))
        // 画面外へ大きく出ていても、サブが無いなら手放さない。
        #expect(!MonitorManager.isOutsideMain(CGRect(x: 9000, y: 0, width: 10, height: 10), monitors: [main]))
    }

    // MARK: - 除外理由

    /// **一時的な理由**として扱う。メインへ戻したときに再評価されないと、
    /// 一度サブへ出したウィンドウが二度とタイルされない。
    @Test("サブディスプレイ上は一時的な除外理由")
    func reasonIsTemporary() {
        #expect(UnmanagedReason.otherMonitor.isTransient)
        #expect(WindowDisposition.unmanaged(.otherMonitor).isTiled == false)
    }

    // MARK: - アプリごと非表示との関係

    /// **サブディスプレイのウィンドウを持つアプリはアプリごと隠せない。**
    /// `NSRunningApplication.hide()` はアプリの全ウィンドウを消すので、
    /// 隠すとサブディスプレイのウィンドウまで消えてしまう。
    @Test("サブディスプレイにウィンドウがあるアプリは隠さない")
    func appWithSubDisplayWindowIsNotHidden() {
        let plan = HidePlanner.plan(
            windows: [
                // ワークスペース2（非表示）にあるメイン側のウィンドウ
                HidePlanner.Window(id: 1, pid: 100, workspace: 2),
                // サブディスプレイにあるので常に見えている
                HidePlanner.Window(id: 2, pid: 100, workspace: 1, isAlwaysVisible: true),
            ],
            visibleWorkspaces: [1], hiddenApps: [], strategy: .hideApp)

        #expect(plan.hide.isEmpty, "隠すとサブディスプレイのウィンドウも消える")
        #expect(plan.stash == [1], "隠せないぶんは隅へ寄せる")
    }

    @Test("サブディスプレイのウィンドウは隅寄せの対象にもしない")
    func subDisplayWindowIsNeverStashed() {
        let plan = HidePlanner.plan(
            windows: [HidePlanner.Window(id: 2, pid: 100, workspace: 2, isAlwaysVisible: true)],
            visibleWorkspaces: [1], hiddenApps: [], strategy: .hideApp)

        #expect(plan.hide.isEmpty)
        #expect(plan.stash.isEmpty, "サブディスプレイは触らない")
    }

    @Test("サブディスプレイのウィンドウがあれば非表示から戻す")
    func appIsUnhiddenWhenItHasSubDisplayWindow() {
        let plan = HidePlanner.plan(
            windows: [HidePlanner.Window(id: 2, pid: 100, workspace: 1, isAlwaysVisible: true)],
            visibleWorkspaces: [1], hiddenApps: [100], strategy: .hideApp)

        #expect(plan.unhide == [100])
    }

    @Test("サブディスプレイのウィンドウが無ければ今までどおりアプリごと隠す")
    func unchangedWithoutSubDisplayWindows() {
        let plan = HidePlanner.plan(
            windows: [
                HidePlanner.Window(id: 1, pid: 100, workspace: 2),
                HidePlanner.Window(id: 2, pid: 100, workspace: 3),
            ],
            visibleWorkspaces: [1], hiddenApps: [], strategy: .hideApp)

        #expect(plan.hide == [100])
        #expect(plan.stash.isEmpty)
    }
}

/// `CGWindowList` から、タイル判定と取りこぼし検出に使う情報を読む。
@Suite("画面一覧")
struct ScreenWindowsTests {

    @Test("持ち主のプロセスを読む")
    func readsTheOwnerPID() {
        let parsed = ScreenWindows.parse([
            [
                kCGWindowNumber as String: CGWindowID(7),
                kCGWindowLayer as String: 0,
                kCGWindowOwnerPID as String: pid_t(4321),
            ]
        ])
        #expect(parsed[7]?.ownerPID == 4321)
    }

    /// 持ち主が読めないものを 0 にしておくと、拾い直しの対象から自然に外れる。
    @Test("持ち主が無ければ 0")
    func missingOwnerBecomesZero() {
        let parsed = ScreenWindows.parse([
            [kCGWindowNumber as String: CGWindowID(8), kCGWindowLayer as String: 0]
        ])
        #expect(parsed[8]?.ownerPID == 0)
    }

    /// PiP の生成通知が表示より先に来ると、初回は一覧にいないことがある。
    /// 表示後の見張りでは、通常窓だけを残して PiP を拾い直せる必要がある。
    @Test("既知のタイルから常時最前面へ昇格した窓を選ぶ")
    func findsElevatedKnownWindows() {
        let screen = [
            CGWindowID(1): ScreenWindows.Entry(layer: 0, bounds: .zero),
            CGWindowID(2): ScreenWindows.Entry(layer: 3, bounds: .zero),
            CGWindowID(3): ScreenWindows.Entry(layer: 8, bounds: .zero),
        ]

        #expect(
            ScreenWindows.elevatedWindowIDs(in: screen, among: [3, 1, 9, 2]) == [3, 2])
    }

    @Test("画面一覧にまだいない窓は昇格したとは決めつけない")
    func missingWindowsAreNotAssumedElevated() {
        let screen = [
            CGWindowID(1): ScreenWindows.Entry(layer: 0, bounds: .zero)
        ]

        #expect(ScreenWindows.elevatedWindowIDs(in: screen, among: [1, 2]).isEmpty)
    }

    @Test("生成通知が表示より先なら画面一覧へ現れるまで待つ")
    func waitsForAWindowToBecomeVisible() {
        let screen = [
            CGWindowID(1): ScreenWindows.Entry(layer: 0, bounds: .zero)
        ]

        #expect(
            ScreenWindows.shouldWaitForVisibility(
                of: 2, in: screen, attempt: 1, maxAttempts: 10))
        #expect(
            ScreenWindows.shouldWaitForVisibility(
                of: 2, in: nil, attempt: 1, maxAttempts: 10))
        #expect(
            !ScreenWindows.shouldWaitForVisibility(
                of: 1, in: screen, attempt: 1, maxAttempts: 10))
    }

    @Test("画面一覧へ現れない特殊な窓も最後には取り込む")
    func eventuallyAdoptsAnInvisibleWindow() {
        #expect(
            !ScreenWindows.shouldWaitForVisibility(
                of: 2, in: [:], attempt: 10, maxAttempts: 10))
    }
}
