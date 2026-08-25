import AppKit
import CoreGraphics
import Darwin
import Foundation
import CometAccessibility
import CometSupport

/// アプリから取り出した、並行境界を越えられる情報。
///
/// `NSRunningApplication` も `Notification` も `Sendable` ではないため、
/// 通知ハンドラの中で必要な値だけを抜き出してから受け渡す。
struct AppInfo: Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String?
    let isRegular: Bool

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        name = app.localizedName
        isRegular = app.activationPolicy == .regular
    }

    init?(notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return nil }
        self.init(app)
    }
}

/// 状態機械の中核。全ての状態変更はここを通る。
///
/// - Important: **メインスレッドで同期 AX 呼び出しを行わないこと。**
///   AX 呼び出しは対象アプリの都合で最大6秒ブロックしうる。ここがブロックすると
///   ホットキーも通知処理も描画も止まる。
///   AX に触る処理は全て `applierPool` のキューへ回し、結果は `Task { @MainActor }` で戻す。
@MainActor
public final class Engine: WindowResolving {

    private let registry = WindowRegistry()
    /// ウィンドウ ID → AX 要素。台帳を AX 非依存に保つため別に持つ。
    private var elements: [CGWindowID: AXElement] = [:]
    /// AX 要素 → ウィンドウ ID。破棄通知では要素しか渡って来ず、
    /// 破棄済み要素には問い合わせられないので逆引きが要る。
    private var idsByElement: [AXElement: CGWindowID] = [:]

    private let applierPool: ApplierPool
    private let observerHub: AXObserverHub
    private let monitors: MonitorManager
    private let scheduler: FrameScheduler
    private let log: Log

    /// 再配置が予約済みか。同一ランループ内の複数回要求を1回にまとめる。
    private var isRelayoutScheduled = false

    /// アプリが縮小を拒否した実績から学習した最小寸法。
    /// 例: Chrome の最小高さは実測 469pt。
    private var minimumSizes: [CGWindowID: CGSize] = [:]

    /// レイアウトが定めた矩形。外部から動かされたときの戻し先になる。
    private var desiredFrames: [CGWindowID: CGRect] = [:]

    /// 「これ以上は寄せられない」と分かった目標と、そのときの実際の矩形。
    ///
    /// **押し合いを終わらせるために要る。** 文字セル単位でしかリサイズできない
    /// アプリ（端末など）は目標にぴったり収まらない。補正で諦めたあと、見張りが
    /// 「ずれている」と判定してまた戻しに行くと、**20秒ごとに無駄な AX 往復を
    /// 繰り返し続ける**（実機で 47 秒に 13 回、約 52 往復を観測）。
    ///
    /// 同じ目標に対して同じ実測へ落ち着いたなら、それがそのウィンドウの限界。
    /// 落ち着いたものとして扱い、目標が変わったときだけ試し直す。
    private var toleratedFrames: [CGWindowID: (target: CGRect, actual: CGRect)] = [:]

    /// 利用者が選んだフローティング。**判定とは別に覚える。**
    ///
    /// 判定の結果（``WindowDisposition``）に混ぜると、最小化・サブディスプレイ・
    /// Cmd+H から戻ってきたときに指定が消えてタイルへ戻ってしまう
    ///（`.unmanaged(...)` を経由した時点でフローティングの記憶が失われる）。
    private var floatingWindows: Set<CGWindowID> = []

    /// comet 自身が非表示ワークスペースのために隠したアプリ。
    ///
    /// **利用者の Cmd+H と区別するために要る。** 区別しないと、利用者が隠した
    /// アプリを次の再配置で勝手に表示へ戻してしまう（実機で Parsec が起動直後に
    /// 表示へ戻された）。
    private var cometHiddenApps: Set<pid_t> = []
    /// 外部変更への反応の頻度制限用。
    private var restoreAttempts: [CGWindowID: (since: Date, count: Int)] = [:]

    /// ワークスペースの集合。**タイル配置のルートはワークスペースごとに持つ。**
    ///
    /// **レイアウト（分割構造と各分割の比率）が唯一の正**であり、ウィンドウの矩形は
    /// ここから導出される。ウィンドウ側の状態は常に上書き対象で、
    /// 追従しなければ補正し、それでも駄目なら制約として学習してレイアウト側が譲る。
    private let workspaces: WorkspaceManager

    /// 表示中のワークスペースのルート。
    private var root: ContainerNode { workspaces.active.root }

    /// 初回配置を待たせないウィンドウ。**症状A（デフォルト位置に一瞬出る）の対策。**
    ///
    /// SIP 有効下では他プロセスのウィンドウの初回描画を止められないので、
    /// 「通知を受けてから適用が終わるまで」を短くするしかない。
    private var priorityWindows: Set<CGWindowID> = []

    /// 再配置のあとにフォーカスを戻すべきワークスペース。
    ///
    /// 切替では**目標矩形を積んだあと**にフォーカスを動かす必要がある。
    private var pendingFocusRestore: WorkspaceID?

    /// 次の再配置が「ワークスペースへ復帰した直後」か。
    ///
    /// **このときだけサイズの設定を省ける。** 通常の再配置でも省いてしまうと、
    /// 最小寸法の学習やギャップの変更で寸法が変わったときに反映されない。
    private var restoringWorkspaces: Set<WorkspaceID> = []

    /// 退避させたときの矩形。
    ///
    /// フローティングは配置計算の対象外なので、戻すべき位置をここで覚えておく。
    /// 退避すると `observedFrame` は退避先に上書きされ、元の位置が分からなくなる。
    private var stashedFrames: [CGWindowID: CGRect] = [:]

    /// 直近のレイアウト。動いた辺がどの分割の境界にあたるかの照合と、
    /// `resize` で点数を比率へ直すために使う。
    /// 直近のレイアウト。ワークスペースごとに持つ。
    ///
    /// **2画面では同時に2つのレイアウトが生きている。** 1つしか持たないと、
    /// 片方のモニタで縁をドラッグしたときに反対側のレイアウトと突き合わせて
    /// 見当違いのコンテナを動かす。
    private var lastLayouts: [WorkspaceID: LayoutEngine.Result] = [:]

    /// 今フォーカスされているウィンドウ。新規ウィンドウの挿入位置とコマンドの対象になる。
    private var focusedWindowID: CGWindowID?

    /// フォーカスが指している階層。0 = ウィンドウ自身、1 = その親コンテナ、…
    ///
    /// i3 の `focus parent` / `focus child`。**入れ子をコンテナごと動かす・向きを変える**
    /// にはこれが要る。`move` / `resize` / `layout` の対象がここで決まる。
    ///
    /// - Important: **本当にフォーカスが動いたら必ず 0 に戻す。** 戻さないと、
    ///   次にウィンドウを選んだつもりでコンテナごと動いて驚く。
    private var focusedAncestorDepth = 0

    /// 次に開くウィンドウの入り方の予約（i3 の `split h` / `split v`）。
    ///
    /// **その場では木を変えない。** 子が1つのコンテナは正規化で潰されるので、
    /// 作っても残らない。次の1枚が来たときに使う予約として持つ。
    private var pendingSplit: (windowID: CGWindowID, orientation: Orientation)?

    /// `exec` で起こしたプロセス。**終了まで参照を残して確実に回収する。**
    private var launchedProcesses: [Process] = []
    /// フォーカスの新しさを比べるための単調増加値。時刻そのものは要らない。
    private var focusCounter: UInt64 = 0

    public var normalization = NormalizationConfig.default
    /// 新しいウィンドウの入り方。既定は dwindle。
    public var insertionStrategy = TreeSync.InsertionStrategy.split
    /// ルートの分割方向の決め方。
    public var defaultOrientation = DefaultOrientation.auto
    /// ウィンドウルール。**初めて見るウィンドウにだけ**当てる。
    public var windowRules: [WindowRule] = []
    /// 非表示ワークスペースのウィンドウの隠し方。
    ///
    /// `hide-app` は完全に消える代わりに粒度がアプリ単位。表示中のワークスペースにも
    /// ウィンドウを持つアプリは自動的に隅寄せへ落ちる。
    public var hiddenWindowStrategy = HiddenWindowStrategy.hideApp

    /// 非表示ワークスペースのウィンドウがアクティブになったら、そちらへ移るか。
    ///
    /// 画面外退避方式では Cmd+Tab や Dock から非表示のウィンドウを選べてしまい、
    /// 「アプリは前面だがウィンドウが見えない」状態になる。
    public var focusFollowsActivation = true

    /// 表示中のワークスペースの番号をもう一度押したら直前へ戻るか
    ///（i3 の `workspace_auto_back_and_forth`）。
    public var workspaceAutoBackAndForth = false

    /// マウスポインタが乗ったウィンドウへフォーカスを移すか（i3 の `focus_follows_mouse`）。
    ///
    /// **i3 の既定は有効**だが、comet では無効を既定にしている。macOS はクリックで
    /// フォーカスを移す前提で作られており、乗せただけで前面が変わると
    /// 「触っていないのにウィンドウが入れ替わる」と受け取られやすい。
    /// 方向フォーカスが端で反対側へ回るか（i3 の `focus_wrapping`）。
    ///
    /// **i3 の既定は有効**だが、comet では無効を既定にしている。回ると
    /// 「右端で `right` を押したら左端へ飛ぶ」ことになり、どこへ行くのかが
    /// 押す前に読めない。2枚だけ並べているときの往復が欲しい人向けの設定。
    public var focusWrapping = false

    public var focusFollowsMouse = false {
        didSet {
            guard focusFollowsMouse != oldValue else { return }
            focusFollowsMouse ? startMouseTracking() : stopMouseTracking()
        }
    }
    /// アプリ巡回で「続けて押している」とみなす時間。0 なら毎回組み直す。
    public var focusCycleReset: TimeInterval = 1.5
    /// 巡回の対象範囲。
    public var focusCycleScope: FocusCycleScope = .activeWorkspace
    /// 押し続けている間の巡回の状態。
    private var focusCycleSession = FocusCycler.Session()

    /// フォーカス中のウィンドウが決まったときに呼ばれる。
    ///
    /// **AX の適用完了を待たずに呼ぶ。** 枠線を先に着地させると遅延が視覚的に隠れる
    /// フォーカス先が無いときは `nil`。
    public var onFocusedFrameChanged: (@MainActor (FocusedWindow?) -> Void)?

    /// フォーカスしていないタイルの矩形が変わったときに呼ばれる。
    ///
    /// **フォーカス中の1枚は含めない**（そちらは ``onFocusedFrameChanged`` が受ける）。
    /// 二重に描くと色が混ざる。
    public var onTiledFramesChanged: (@MainActor ([(id: CGWindowID, frame: CGRect)]) -> Void)?

    /// ワークスペースの見え方が変わったときに呼ばれる。
    ///
    /// **ウィンドウ移動の発行より前に呼ぶ。** 壁紙とインジケータは自プロセス側の
    /// 処理なので即座に終わり、切替が速く見える（症状D）。
    ///
    /// 2画面では壁紙もインジケータもモニタごとに違うので、「今のワークスペース」
    /// 1つでは表せない。**どの番号にウィンドウが居るか**も渡す（i3 のバーと
    /// 同じ見え方にするために要る）。
    public var onWorkspaceStatusChanged: (@MainActor (WorkspaceStatus) -> Void)?

    /// 並べる対象のディスプレイ。既定は全部（i3 は全ての output をタイルする）。
    public var monitorScope: MonitorScope = .all {
        didSet {
            guard monitorScope != oldValue else { return }
            syncMonitorAssignment()
            workspaces.markAllLayoutsDirty()
            relayout()
        }
    }
    private var managesAllMonitors: Bool { monitorScope == .all }
    /// 追従を諦めたウィンドウをフローティングへ降格させる、ずれの下限。
    ///
    /// 文字セル単位への丸め（WezTerm）や最小寸法は数十 pt のずれで収まる。
    /// これを降格の対象にすると常用しているウィンドウが勝手に浮くので、
    /// **「明らかに無視している」大きさだけを対象にする**。
    public var floatingDemotionThreshold: CGFloat = 50
    public var gaps: Gaps
    /// レイアウトを計算するがウィンドウは動かさない。
    /// 他の WM が動いている環境でも安全に検証できるようにするための逃げ道。
    public let isDryRun: Bool

    public init(
        gaps: Gaps = Gaps(inner: 5, outer: 5),
        performance: PerformanceOptions = PerformanceOptions(),
        workspaceCount: Int = 10,
        dryRun: Bool = false,
        log: Log = .shared
    ) {
        self.workspaces = WorkspaceManager(count: workspaceCount)
        self.gaps = gaps
        self.isDryRun = dryRun
        self.log = log
        let pool = ApplierPool()
        self.applierPool = pool
        let hub = AXObserverHub(
            applierPool: pool, messagingTimeout: Float(performance.axTimeout), log: log)
        hub.disablesEnhancedUserInterface = performance.disablesEnhancedUserInterface
        self.observerHub = hub
        self.monitors = MonitorManager(log: log)
        let scheduler = FrameScheduler(
            applierPool: pool, interval: performance.applyInterval,
            maxCorrections: performance.maxCorrections,
            timing: TimingRecorder(isEnabled: performance.isTimingEnabled), log: log)
        scheduler.isDryRun = dryRun
        self.scheduler = scheduler
    }

    public var managedWindowCount: Int { registry.count }
    public var tiledWindowCount: Int { registry.tiledIDs.count }
    /// 表示中のワークスペースとツリーの形。`1: H[1, V[2, 3]]` の記法で返る。診断用。
    public var treeDescription: String { "\(workspaces.activeID): \(root)" }
    public var activeWorkspaceID: WorkspaceID { workspaces.activeID }
    public var workspaceCount: Int { workspaces.count }

    /// 適用のレイテンシをアプリ別に整形した行。`[debug] timing = true` のときだけ中身が入る。
    ///
    /// **「どのアプリが足を引っ張っているか」がここで分かる**。
    public var timingReport: [String] {
        scheduler.timing.report { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }
    public var isTimingEnabled: Bool { scheduler.timing.isEnabled }

    /// ワークスペースの一覧。**状態バーから読める形にする。**
    ///
    /// 1行1ワークスペースの `key=value` 形式。空のワークスペースは省く
    /// （10 個並べても押す手掛かりにならない）。
    ///
    /// ```
    /// ws=1 state=focused monitor=1 windows=3
    /// ws=2 state=visible monitor=2 windows=1
    /// ws=5 state=hidden windows=2
    /// ```
    public var workspacesDescription: String {
        let occupied = occupiedWorkspaces
        var lines: [String] = []
        for workspace in workspaces.all {
            let monitor = workspaces.monitor(showing: workspace.id)
            guard occupied.contains(workspace.id) || monitor != nil else { continue }
            let state: String
            if workspace.id == workspaces.activeID {
                state = "focused"
            } else if monitor != nil {
                state = "visible"
            } else {
                state = "hidden"
            }
            var parts = ["ws=\(workspace.id)", "state=\(state)"]
            if let monitor { parts.append("monitor=\(monitor)") }
            parts.append("windows=\(registry.visibleIDs(in: workspace.id).count)")
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// ウィンドウの一覧。**title は空白を含むので必ず最後に置く。**
    public var windowsDescription: String {
        let focused = focusedWindowID
        return registry.allIDs.compactMap { id -> String? in
            guard let record = registry[id] else { return nil }
            let kind: String
            switch record.disposition {
            case .tiled: kind = "tiled"
            case .floating: kind = "floating"
            case .unmanaged(let reason): kind = "unmanaged(\(reason))"
            }
            let frame = desiredFrames[id] ?? record.observedFrame
            var parts = [
                "id=\(id)", "pid=\(record.pid)", "ws=\(record.workspace)", "kind=\(kind)",
                "focus=\(id == focused ? "*" : "-")",
            ]
            if let frame {
                parts.append(
                    "frame=\(Int(frame.minX)),\(Int(frame.minY)),"
                        + "\(Int(frame.width))x\(Int(frame.height))")
            }
            parts.append("app=\(record.bundleID ?? "-")")
            // 改行が入ると1行1ウィンドウが崩れる。潰しておく。
            let title = (record.title ?? "").replacingOccurrences(of: "\n", with: " ")
            parts.append("title=\(title)")
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// ディスプレイの一覧。**2画面の設定を状態バーから読むために要る。**
    ///
    /// ```
    /// monitor=1 x=0 y=0 w=1920 h=1080 primary=yes ws=1 focused=yes
    /// ```
    public var monitorsDescription: String {
        monitors.monitors.map { monitor in
            let shown = workspaces.shown(on: monitor.id)
            return [
                "monitor=\(monitor.id)",
                "x=\(Int(monitor.frame.minX))", "y=\(Int(monitor.frame.minY))",
                "w=\(Int(monitor.frame.width))", "h=\(Int(monitor.frame.height))",
                "primary=\(monitor.isPrimary ? "yes" : "no")",
                "ws=\(shown.map(String.init) ?? "-")",
                "focused=\(monitor.id == workspaces.focusedMonitor ? "yes" : "no")",
            ].joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// 全ワークスペースのツリー。空のものは省く。
    public var treesDescription: String {
        workspaces.all.compactMap { workspace -> String? in
            guard !workspace.root.isEmpty else { return nil }
            let mark =
                workspace.id == workspaces.activeID
                ? "*" : (workspaces.isVisible(workspace.id) ? "+" : " ")
            return "ws\(workspace.id)\(mark) \(workspace.root)"
        }.joined(separator: "\n")
    }

    /// 全ワークスペースの状態。**配置がおかしいときの最初の手がかり。**
    ///
    /// 「ツリーの組み方」「所属ワークスペース」「退避の有無」のどこがずれているのかを
    /// 一目で切り分けられるようにする。空のワークスペースは省く。
    public var stateDescription: String {
        var parts: [String] = []
        for workspace in workspaces.all {
            let tiled = registry.tiledIDs(in: workspace.id)
            let floating = registry.visibleIDs(in: workspace.id).filter {
                registry[$0]?.disposition.isFloating == true
            }
            guard !tiled.isEmpty || !floating.isEmpty else { continue }

            let mark =
                workspace.id == workspaces.activeID
                ? "*" : (workspaces.isVisible(workspace.id) ? "+" : "")
            var part = "ws\(workspace.id)\(mark) \(workspace.root)"
            if !floating.isEmpty {
                part += " float\(floating)"
            }
            if workspace.isLayoutDirty {
                part += " (要サイズ再適用)"
            }
            parts.append(part)
        }
        if parts.isEmpty {
            parts.append("ウィンドウなし")
        }
        if !stashedFrames.isEmpty {
            parts.append("隅寄せ \(stashedFrames.count) 枚")
        }
        let hidden = Set(registry.allIDs.compactMap { registry[$0]?.pid })
            .filter { NSRunningApplication(processIdentifier: $0)?.isHidden == true }
        if !hidden.isEmpty {
            parts.append("非表示アプリ \(hidden.count) 個")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - 起動

    public func start() {
        scheduler.setResolver(self)

        monitors.onChange = { [weak self] in
            guard let self else { return }
            self.log.info("ディスプレイ構成が変わった")
            self.syncMonitorAssignment()
            // 表示中でないワークスペースも寸法が合わなくなる。退避先も動くので、
            // **退避中のウィンドウを新しい退避先へ動かし直さないと画面に現れる**
            // 再配置が全ワークスペース分を積み直す。
            self.workspaces.markAllLayoutsDirty()
            self.relayout()
        }
        monitors.start()
        syncMonitorAssignment()

        observerHub.onEvent = { [weak self] event in
            self?.handle(event)
        }

        observeApplicationLifecycle()
        adoptRunningApplications()
        startLayoutGuard()
    }

    public func stop() {
        stopMouseTracking()
        layoutGuardTimer?.invalidate()
        layoutGuardTimer = nil
        observerHub.stop()
        registry.removeAll()
        elements.removeAll()
        idsByElement.removeAll()
        for workspace in workspaces.all {
            TreeSync.reconcile(root: workspace.root, tiled: [], normalization: normalization)
        }
        stashedFrames.removeAll()
        lastLayouts.removeAll()
        focusedWindowID = nil
    }

    private func observeApplicationLifecycle() {
        let center = NSWorkspace.shared.notificationCenter

        // 起動を検知した時点で監視を張る。ウィンドウが生まれてからでは
        // 通知の登録が間に合わず、初回配置が遅れて「一瞬デフォルト位置に出る」（症状A）。
        //
        // Notification と NSRunningApplication は Sendable ではないので、
        // クロージャの中で必要な値だけを取り出してから MainActor へ渡す。
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = AppInfo(notification: note) else { return }
            MainActor.assumeIsolated {
                self?.adopt(info)
            }
        }

        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = AppInfo(notification: note) else { return }
            MainActor.assumeIsolated {
                self?.forget(pid: info.pid)
            }
        }

        // **Cmd+H を最小化と同じ扱いにするために要る。**
        // 隠されたことを知らないと、領域だけ確保されて配置に穴が開き、
        // 次の再配置では逆に勝手に表示へ戻してしまう（実機で観測）。
        center.addObserver(
            forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = AppInfo(notification: note) else { return }
            MainActor.assumeIsolated {
                self?.applicationDidHide(pid: info.pid, name: info.name)
            }
        }

        center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = AppInfo(notification: note) else { return }
            MainActor.assumeIsolated {
                self?.applicationDidUnhide(pid: info.pid, name: info.name)
            }
        }
    }

    /// アプリが隠された。
    ///
    /// comet 自身が隠したぶんは何もしない。利用者が隠したなら、そのアプリの
    /// ウィンドウを列から外して残りを詰める（最小化と同じ扱い）。
    private func applicationDidHide(pid: pid_t, name: String?) {
        guard !cometHiddenApps.contains(pid) else { return }
        let affected = registry.ids(pid: pid).filter {
            registry[$0]?.disposition.acceptsFocusTracking == true
        }
        guard !affected.isEmpty else { return }

        log.info("\(name ?? "?") が隠された（Cmd+H）。\(affected.count) 枚を配置から外す")
        for id in affected {
            registry.update(id) { $0.disposition = .unmanaged(.userHidden) }
            desiredFrames.removeValue(forKey: id)
            toleratedFrames.removeValue(forKey: id)
            layoutGuard.forget(id)
            scheduler.forget(id)
            if focusedWindowID == id {
                focusedWindowID = nil
            }
        }
        relayout()
    }

    /// アプリが表示に戻った。隠していた間に外したウィンドウを拾い直す。
    private func applicationDidUnhide(pid: pid_t, name: String?) {
        cometHiddenApps.remove(pid)
        let restored = registry.ids(pid: pid).filter {
            registry[$0]?.disposition == .unmanaged(.userHidden)
        }
        guard !restored.isEmpty else { return }
        log.info("\(name ?? "?") が表示に戻った。\(restored.count) 枚を配置へ戻す")
        // 隠れている間に属性が変わっていることがあるので、走査で読み直す。
        rescan(pid: pid)
    }

    private func adoptRunningApplications() {
        let apps = NSWorkspace.shared.runningApplications
            .map(AppInfo.init)
            .filter { $0.isRegular && $0.pid != getpid() }

        // 走査は非同期に完了するので、全部揃うまで数えておく。
        // 揃った時点で並び順を整えないと、起動のたびにウィンドウの配置が入れ替わる。
        pendingInitialScans = apps.count
        for app in apps {
            adopt(app, isInitial: true)
        }
        finishInitialAdoptionIfReady()

        // 応答しないアプリがあると走査が返らず、配置が永久に保留になる。
        // 一定時間で打ち切って、返ってきた分だけで配置する。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.initialAdoptionTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasFinishedInitialAdoption else { return }
                self.log.warn(
                    "起動時の走査が \(Self.initialAdoptionTimeout) 秒で完了しなかった"
                        + "（未完了 \(self.pendingInitialScans) 件）。揃った分で配置する。")
                self.pendingInitialScans = 0
                self.finishInitialAdoptionIfReady()
            }
        }
    }

    private static let initialAdoptionTimeout: TimeInterval = 3

    /// 起動時の走査で完了待ちのアプリ数。
    private var pendingInitialScans = 0

    private func adopt(_ info: AppInfo, isInitial: Bool = false) {
        // メニューバー常駐やバックグラウンドのみのプロセスはウィンドウを持たない。
        guard info.isRegular, info.pid != getpid() else {
            if isInitial { completeInitialScan() }
            return
        }

        let pid = info.pid
        guard observerHub.attach(pid: pid), let application = observerHub.application(for: pid)
        else {
            if isInitial { completeInitialScan() }
            return
        }

        log.debug("アプリを監視: \(info.name ?? "?") (pid=\(pid))")

        let bundleID = info.bundleID
        applierPool.queue(for: pid).async {
            let scan = AXBridge.scanWindows(of: application.raw)
            Task { @MainActor in
                // 走査の内訳を残す。ウィンドウが並ばないときに
                // 「そもそも見えていない」のか「除外されている」のかを切り分けられる。
                if scan.elementCount > 0 || !scan.windows.isEmpty {
                    let reasons =
                        scan.identifierErrors.isEmpty
                        ? "" : "（\(scan.identifierErrors.joined(separator: " / "))）"
                    self.log.debug(
                        "走査 pid=\(pid) \(info.name ?? "?"): 要素 \(scan.elementCount) 枚, "
                            + "ID取得失敗 \(scan.missingIdentifier)\(reasons), "
                            + "属性取得失敗 \(scan.missingAttributes)")
                    self.identifierFailures += scan.missingIdentifier
                    self.identifierFailureReasons.formUnion(scan.identifierErrors)
                } else {
                    self.log.trace(
                        "走査 pid=\(pid) \(info.name ?? "?"): ウィンドウなし"
                            + (scan.listError.map { " (AXWindows: \($0))" } ?? ""))
                }
                self.register(scan.windows, pid: pid, bundleID: bundleID)
                if isInitial { self.completeInitialScan() }
            }
        }
    }

    private func completeInitialScan() {
        guard pendingInitialScans > 0 else { return }
        pendingInitialScans -= 1
        finishInitialAdoptionIfReady()
    }

    /// 起動時の走査が一巡したら、ウィンドウ ID 昇順に整列させる。
    ///
    /// 走査の完了順は実行ごとに変わるため、そのままだと同じ環境で起動しても
    /// ウィンドウの並びが入れ替わる。ID はウィンドウ生成順に増えるので、
    /// 昇順に並べると「先に開いていたものが前」になり再現性がある。
    private func finishInitialAdoptionIfReady() {
        guard pendingInitialScans == 0, !hasFinishedInitialAdoption else { return }
        hasFinishedInitialAdoption = true
        registry.sort { $0.id < $1.id }
        log.debug("起動時の走査が完了: ウィンドウ \(registry.count) 枚（タイル対象 \(registry.tiledIDs.count) 枚）")

        // 1枚も認識できないのは「ウィンドウが無い」か「AX が使えていない」のどちらか。
        // ここで黙ると、何も並ばない原因が実装なのか権限なのか分からなくなる。
        //
        // ad-hoc 署名の identifier には実行ファイルの内容ハッシュが入るため、
        // **再ビルドすると別アプリとして扱われて権限が外れる。**
        if registry.count == 0, identifierFailures > 0 {
            log.warn(
                """
                ウィンドウを1枚も認識できなかった（ID 取得に \(identifierFailures) 件失敗:
                \(identifierFailureReasons.sorted().joined(separator: " / "))）。
                再ビルドでアクセシビリティ権限が外れた可能性が高い。
                システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可し直すか、
                ./scripts/make-signing-cert.sh で固定の署名 ID を作ると再ビルドをまたいで維持される。
                """)
        }
        relayout()

        // **起動直後のフォーカスを実態に合わせる。**
        //
        // これをしないと `focusedWindowID` が nil のままで、方向フォーカスも
        // アプリ内の巡回も「ツリーの先頭」を起点にしてしまう。利用者が今見ている
        // ウィンドウと違う場所から動き出すので、最初の1回だけ挙動が読めなくなる。
        if let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            refreshFocus(pid: frontmost)
        }
    }

    private var hasFinishedInitialAdoption = false
    /// 起動時の走査で ID 取得に失敗した件数と理由。全滅したときの診断に使う。
    private var identifierFailures = 0
    private var identifierFailureReasons: Set<String> = []

    private func forget(pid: pid_t) {
        let removed = registry.removeAll(pid: pid)
        guard !removed.isEmpty || observerHub.application(for: pid) != nil else { return }

        for id in removed {
            if let element = elements.removeValue(forKey: id) {
                idsByElement.removeValue(forKey: element)
            }
            scheduler.forget(id)
            minimumSizes.removeValue(forKey: id)
            desiredFrames.removeValue(forKey: id)
            stashedFrames.removeValue(forKey: id)
            priorityWindows.remove(id)
            restoreAttempts.removeValue(forKey: id)
            toleratedFrames.removeValue(forKey: id)
            floatingWindows.remove(id)
            layoutGuard.forget(id)
            missingWindows.forget(id)
        }
        cometHiddenApps.remove(pid)
        observerHub.detach(pid: pid)
        applierPool.removeQueue(for: pid)

        log.debug("アプリを解放: pid=\(pid) (ウィンドウ \(removed.count) 枚)")
        relayout()
    }

    // MARK: - ウィンドウの登録

    /// 判定結果に、こちら側が持っている事情を重ねる。
    ///
    /// 判定（``WindowClassifier``）が見ているのは「そもそも管理できるか」だけ。
    /// 隠されているか、どのディスプレイに居るか、利用者がフローティングを選んだかは
    /// AX からは分からないのでここで重ねる。
    ///
    /// - Important: **フローティングの選択は ``floatingWindows`` が唯一の正。**
    ///   判定結果に混ぜると、最小化・サブディスプレイ・Cmd+H を経由した時点で
    ///   `.unmanaged(...)` に上書きされて記憶が失われ、戻ってきたときに
    ///   タイルへ化ける。
    ///
    /// ルールを当てるのは**初めて見るウィンドウのときだけ**。あとから当て直すと
    /// `layout floating tiling` で戻した選択を上書きしてしまう。
    private func resolveDisposition(
        _ classified: WindowDisposition, id: CGWindowID, pid: pid_t, bundleID: String?,
        title: String?, frame: CGRect?
    ) -> WindowDisposition {
        // **利用者が Cmd+H で隠したアプリのウィンドウは列から外す。**
        // 外さないと、隠れているのに領域だけ確保されて配置に穴が開き、
        // 次の再配置では逆に勝手に表示へ戻される（実機で観測）。
        // comet 自身が非表示ワークスペースのために隠したものは対象外。
        if isUserHidden(pid: pid) {
            return .unmanaged(.userHidden)
        }
        // 全モニタを並べる設定（既定）ではここで外さない。切っている場合だけ、
        // メインの外にあるウィンドウを素の macOS へ返す（従来の挙動）。
        if !managesAllMonitors, let frame,
            MonitorManager.isOutsideMain(frame, monitors: monitors.monitors)
        {
            return .unmanaged(.otherMonitor)
        }
        guard classified.isTiled else { return classified }

        if floatingWindows.contains(id) { return .floating }
        // 既知のウィンドウにルールを当て直さない。
        guard registry[id] == nil else { return classified }
        let matched = windowRules.first {
            $0.action == .float && $0.matches(bundleID: bundleID, title: title)
        }
        guard matched != nil else { return classified }
        log.debug("[\(id)] \(title?.prefix(40) ?? "?") はルールによりフローティング")
        floatingWindows.insert(id)
        return .floating
    }

    /// 利用者がアプリごと隠しているか（Cmd+H）。
    ///
    /// comet 自身が隠したものは含めない。区別しないと、ワークスペース切替のために
    /// 隠したウィンドウまで「利用者が隠した」と見なして列から外してしまう。
    private func isUserHidden(pid: pid_t) -> Bool {
        guard !cometHiddenApps.contains(pid) else { return false }
        return NSRunningApplication(processIdentifier: pid)?.isHidden == true
    }

    /// 新しいウィンドウをどのモニタのワークスペースへ入れるか。
    public enum Placement: Sendable {
        /// 今フォーカスしているモニタ。**新しく開いたウィンドウはこちら**
        ///（i3 と同じ。アプリが決めた初期位置に引っ張られない）。
        case focusedMonitor
        /// 今いる位置のモニタ。**起動時の走査はこちら**（既存の置き場所を尊重する）。
        case byPosition
    }

    private func workspaceForNewWindow(frame: CGRect?, placement: Placement) -> WorkspaceID {
        guard placement == .byPosition, let frame, let monitor = monitors.owner(of: frame),
            let shown = workspaces.shown(on: monitor.id)
        else {
            return workspaces.activeID
        }
        return shown
    }

    /// ルールで決められた置き場所（i3 の `assign`）。
    ///
    /// **初めて見るウィンドウにだけ効く。** 呼び出し側が既知かどうかを判断する。
    /// 番号が存在しない場合は無視する（設定の数を減らしたときに行き場を失わせない）。
    private func ruleWorkspace(bundleID: String?, title: String?) -> WorkspaceID? {
        for rule in windowRules {
            guard case .moveToWorkspace(let id) = rule.action,
                rule.matches(bundleID: bundleID, title: title)
            else { continue }
            guard workspaces[id] != nil else {
                log.warn("ルールの行き先 ws\(id) は存在しない（1〜\(workspaces.count)）")
                return nil
            }
            return id
        }
        return nil
    }

    private func register(
        _ windows: [DiscoveredWindow], pid: pid_t, bundleID: String?, immediately: Bool = false,
        placement: Placement = .byPosition
    ) {
        guard !windows.isEmpty else { return }

        // 階層は AX からは分からないので別に取る。**まとめて1回だけ**（1枚ずつ引くと
        // 往復が増えるうえ、実測でも一覧を取るほうが速い）。
        let screen = ScreenWindows.snapshot()

        for window in windows {
            let disposition = resolveDisposition(
                WindowClassifier.classify(
                    WindowSnapshot(
                        role: window.attributes.role,
                        subrole: window.attributes.subrole,
                        isFullScreen: window.attributes.isFullScreen,
                        isMinimized: window.attributes.isMinimized,
                        size: window.attributes.size ?? .zero,
                        layer: screen?[window.id]?.layer)),
                id: window.id, pid: pid, bundleID: bundleID, title: window.attributes.title,
                frame: window.attributes.frame)

            elements[window.id] = window.element
            idsByElement[window.element] = window.id
            // 新しいウィンドウは今見えているワークスペースに入る。既知のウィンドウは
            // 所属を保つ（属性の更新で別のワークスペースへ飛ばさない）。
            //
            // **フォーカス履歴も引き継ぐ。** 走査は取りこぼしの拾い直しや Cmd+H からの
            // 復帰でも走るので、捨てるとアプリ巡回の並びが走査のたびに初期化される。
            let known = registry[window.id]
            registry.insert(
                WindowRecord(
                    id: window.id,
                    pid: pid,
                    disposition: disposition,
                    title: window.attributes.title,
                    bundleID: bundleID,
                    observedFrame: window.attributes.frame,
                    workspace: known?.workspace
                        ?? ruleWorkspace(
                            bundleID: bundleID, title: window.attributes.title)
                        ?? workspaceForNewWindow(
                            frame: window.attributes.frame, placement: placement),
                    lastFocusedAt: known?.lastFocusedAt ?? 0))

            observerHub.observe(window: window.element, pid: pid)

            let title = window.attributes.title?.prefix(50) ?? "?"
            switch disposition {
            case .tiled:
                log.debug("追加 [\(window.id)] \(title)")
            case .floating:
                log.debug("追加 [\(window.id)] \(title)（フローティング）")
            case .unmanaged(let reason):
                log.trace("除外 [\(window.id)] \(title): \(reason)")
            }
        }
        relayout(immediately: immediately)
    }

    // MARK: - イベント

    private func handle(_ event: AXEvent) {
        switch event {
        case .windowCreated(let pid, let element):
            adoptWindow(element, pid: pid)

        case .elementDestroyed(_, let element):
            releaseWindow(element)

        case .windowMiniaturized(let pid, let element),
            .windowDeminiaturized(let pid, let element):
            // 最小化は一時的な除外理由なので、状態が変わったら評価し直す。
            refreshWindow(element, pid: pid)

        case .windowMoved(let pid, let element), .windowResized(let pid, let element):
            handleExternalChange(element, pid: pid)

        case .focusedWindowChanged(let pid, let element):
            noteFocus(element, pid: pid)

        case .applicationActivated(let pid):
            refreshFocus(pid: pid)
        }
    }

    // MARK: - フォーカス

    /// フォーカスされたウィンドウを記録する。
    ///
    /// 通知に載っている要素は登録時のものと別インスタンスでも `CFEqual` で一致するので
    /// 逆引きが効く。効かないときだけアプリに問い合わせ直す。
    private func noteFocus(_ element: AXElement, pid: pid_t) {
        if let id = idsByElement[element] {
            noteFocused(id)
            return
        }
        refreshFocus(pid: pid)
    }

    /// アプリに「今どのウィンドウがフォーカスされているか」を問い合わせる。
    ///
    /// `AXApplicationActivated` は前面に来たアプリしか伝えないので、ウィンドウを
    /// 特定するには1往復が要る。利用者の操作に伴うものなので頻度は低い。
    private func refreshFocus(pid: pid_t) {
        guard let application = observerHub.application(for: pid) else { return }
        applierPool.queue(for: pid).async {
            let id = AXBridge.focusedWindowID(of: application.raw)
            Task { @MainActor in
                guard let id else { return }
                self.noteFocused(id)
            }
        }
    }

    /// 非表示ワークスペースのウィンドウがアクティブになったら、そちらへ移る。
    ///
    /// 画面外退避方式では Cmd+Tab や Dock から非表示のウィンドウを選べてしまう。
    /// 何もしないと「アプリは前面だがウィンドウが見えない」状態になる。
    private func followActivationIfNeeded(_ id: CGWindowID) {
        // **切り替えた直後は追従しない。**
        //
        // 非表示ワークスペースのアプリを隠すと、macOS は残ったアプリのどれかを
        // 前面にする。それが**今まさに隠したアプリ自身**だと、macOS が表示へ戻して
        // しまい「非表示ワークスペースのウィンドウがアクティブになった」と読める。
        // 追従すると切り替えたそばから元へ引き戻される。
        //
        // 実機で観測: `workspace 2` の 39ms 後に ws1 へ戻り、隠したアプリも
        // 表示へ戻っていた（切替が効かないように見える）。
        //
        // 利用者が番号を押した意図は「そこへ行く」なので、**こちらが原因で起きた
        // 前面化には従わない**。猶予を過ぎたあとの Cmd+Tab には普通に追従する。
        let sinceSwitch = ProcessInfo.processInfo.systemUptime - lastWorkspaceSwitchAt
        guard sinceSwitch > Self.activationFollowGrace else {
            log.trace("[\(id)] のアクティブ化は切替の直後なので追従しない")
            return
        }
        guard focusFollowsActivation, let record = registry[id],
            // **どのワークスペースの配置にも属さないウィンドウでは切り替えない。**
            // サブディスプレイのウィンドウ（`manage = "main"` のとき）は
            // 所属ワークスペースに関係なく常に見えているので、隠すも出すも無い。
            //
            // これを見ないと実機で往復が起きた: 空のワークスペースへ切り替える →
            // アプリを隠す → macOS がサブディスプレイのウィンドウを前面にする →
            // その所属ワークスペース（元の側）へ引き戻される、で**切り替えた
            // そばから元へ戻る**。
            record.disposition.isTiled || record.disposition.isFloating,
            !workspaces.isVisible(record.workspace),
            workspaces[record.workspace] != nil
        else { return }
        let workspace = record.workspace

        log.info("[\(id)] がアクティブになったのでワークスペース \(workspace) へ移る")
        switchWorkspace(to: .index(workspace))
    }

    private func noteFocused(_ id: CGWindowID) {
        guard let record = registry[id] else { return }
        // **ダイアログや拡張機能のポップアップへは移さない。** 追うと枠線がそちらへ飛び、
        // 以降のコマンドの起点も変わる（Chrome の拡張機能パネルで実際に起きた）。
        // 利用者から見れば「元のウィンドウを操作している」ままにする。
        guard record.disposition.acceptsFocusTracking else {
            log.trace("[\(id)] は管理対象外なのでフォーカスを移さない")
            return
        }
        // **隠れているアプリのウィンドウは対象にしない。**
        //
        // `app.hide()` の直後にそのアプリのフォーカス通知が届く。反応すると
        // 見えていないウィンドウがコマンドの対象になり、`focus-follows-activation`
        // が働いて**切り替えたそばから元のワークスペースへ引き戻される**
        //（実機で観測: 空のワークスペースへ切り替えた 46ms 後に戻っていた）。
        //
        // 利用者が Cmd+Tab で選んだ場合は macOS が先に表示へ戻すので、
        // そのときは `isHidden` が false になっていて普通に追従する。
        guard NSRunningApplication(processIdentifier: record.pid)?.isHidden != true else {
            log.trace("[\(id)] は隠れているアプリのウィンドウなのでフォーカスを移さない")
            return
        }
        // **階層の選択は本当のフォーカス移動で解除する。** i3 も同じで、
        // 別のウィンドウを選んだ時点で親コンテナの選択は無くなる。
        if focusedWindowID != id {
            focusedAncestorDepth = 0
            if pendingSplit?.windowID != id {
                pendingSplit = nil
            }
        }
        focusedWindowID = id
        focusCounter += 1
        root.findWindow(id)?.lastFocusedAt = focusCounter
        // ツリーの葉はタイル対象しか持たない。アプリ巡回はフローティングや
        // サブディスプレイのウィンドウも対象にするので台帳側にも記録する。
        registry.update(id) { $0.lastFocusedAt = self.focusCounter }
        followFocusedMonitor(id)
        notifyFocusedFrame()
        // フォーカスが移ると「囲まない1枚」が変わる。
        notifyTiledFrames()
        // **どの経路でフォーカスが移っても追従する。** アプリのアクティブ化の
        // 通知だけを見ていると、同じアプリの中で別ワークスペースのウィンドウへ
        // 移ったとき（`focus next-window-in-app` や cycle-scope = "all"）に
        // 通知が来ないため、「フォーカスはあるのに画面に無い」状態になる。
        followActivationIfNeeded(id)
    }

    /// 枠線の位置を伝える。
    ///
    /// 目標矩形が分かっていればそれを使う（適用の完了を待たない）。
    /// 分からないもの（フローティングなど）は実測値に合わせる。
    /// - Parameter measured: 目標に届かなかったときの実測値。
    ///   **対象が一致するときだけ使う。** 別のウィンドウの実測値を混ぜると枠線が飛ぶ。
    private func notifyFocusedFrame(measured: (id: CGWindowID, frame: CGRect)? = nil) {
        guard let handler = onFocusedFrameChanged else { return }
        guard let id = focusedWindowOnActiveWorkspace(), let record = registry[id] else {
            handler(nil)
            return
        }
        // 見えていないものは囲まない。ネイティブ全画面と最小化は macOS 側が描画を
        // 持っていくし、サブディスプレイは素の macOS のまま使えるようにしている場所で、
        // どちらも WM の装飾を持ち込む先ではない。
        guard record.disposition.showsFocusBorder else {
            handler(nil)
            return
        }
        let override = measured?.id == id ? measured?.frame : nil
        // `focus parent` で上がっているならコンテナ全体を囲む（i3 と同じ見え方）。
        guard let frame = focusedContainerFrame() ?? override ?? desiredFrames[id]
            ?? record.observedFrame
        else {
            handler(nil)
            return
        }
        // 非表示ワークスペースへ退避したウィンドウ（画面の外）には描かない。
        // **モニタが分からないときは描く。** 起動直後に枠線が出ないほうが困る。
        guard monitors.monitors.isEmpty || MonitorManager.owner(of: frame, among: monitors.monitors) != nil
        else {
            handler(nil)
            return
        }
        handler(FocusedWindow(id: id, frame: frame))
    }

    /// フォーカスしていないタイルの矩形を伝える。
    ///
    /// 覆われているものは外す。枠線は自プロセスのウィンドウで**他のアプリより手前**に
    /// 出るので、覆われた場所に残すと全画面や浮いているウィンドウの上に線が浮く。
    private func notifyTiledFrames() {
        guard let handler = onTiledFramesChanged else { return }
        let focused = focusedWindowOnActiveWorkspace()
        var frames: [(id: CGWindowID, frame: CGRect)] = []
        for pair in workspaces.visiblePairs {
            // 全画面が出ている間は他のタイルが隠れている。1枚も描かない。
            guard pair.workspace.fullscreenWindowID == nil else { continue }
            // 浮いているウィンドウは手前にある。重なっているタイルの枠は描かない。
            let floating = registry.visibleIDs(in: pair.workspace.id).compactMap {
                id -> CGRect? in
                guard registry[id]?.disposition.isFloating == true else { return nil }
                return registry[id]?.observedFrame
            }
            for id in registry.tiledIDs(in: pair.workspace.id) where id != focused {
                guard let frame = desiredFrames[id] else { continue }
                guard !floating.contains(where: { $0.intersects(frame) }) else { continue }
                frames.append((id: id, frame: frame))
            }
        }
        handler(frames)
    }

    /// コマンドの対象になるウィンドウノード。
    ///
    /// フォーカスが分からない状況（起動直後など）では、最後にフォーカスされた葉に落とす。
    /// 何も起きないよりは予測できる動きをするほうがよい。
    private func focusedNode() -> WindowNode? {
        if let id = focusedWindowID, let node = root.findWindow(id) { return node }
        return TreeOperations.descendToLeaf(root)
    }

    /// コマンドの対象ノード。`focus parent` で上がっていればコンテナ。
    ///
    /// i3 と同じく、`move` / `resize` / `layout` はここが返すノードに対して働く。
    private func focusedTarget() -> Node? {
        guard let window = focusedNode() else { return nil }
        var node: Node = window
        for _ in 0..<focusedAncestorDepth {
            guard let parent = node.parent else { break }
            node = parent
        }
        return node
    }

    /// `focus parent` で選んでいるコンテナが占める矩形。
    ///
    /// **枠線をここへ出さないと、何を選んでいるのかが分からない。**
    /// コンテナの領域は葉の矩形の外接矩形と一致する。
    private func focusedContainerFrame() -> CGRect? {
        guard focusedAncestorDepth > 0, let container = focusedTarget() as? ContainerNode
        else { return nil }
        let rects = container.windowIDs.compactMap { desiredFrames[$0] }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// 「フォーカス中のウィンドウ」を対象にするコマンドの対象。
    ///
    /// **表示中のワークスペースのものに限る。** Cmd+Tab で非表示ワークスペースの
    /// アプリへ切り替わると、フォーカスは画面外のウィンドウを指しうる。それを
    /// そのまま対象にすると、見えていないウィンドウが動いて何が起きたか分からなくなる。
    private func focusedWindowOnActiveWorkspace() -> CGWindowID? {
        if let id = focusedWindowID, registry[id]?.workspace == workspaces.activeID {
            return id
        }
        // フォーカスが別のモニタのワークスペースにあるなら、そこを対象にする。
        if let id = focusedWindowID, let workspace = registry[id]?.workspace,
            workspaces.isVisible(workspace)
        {
            return id
        }
        return focusedNode()?.windowID
    }

    /// ウィンドウを前面に出してフォーカスする。
    private func focusWindow(_ id: CGWindowID) {
        guard let element = elements[id], let pid = registry[id]?.pid else { return }
        applierPool.queue(for: pid).async {
            AXBridge.focus(element.raw)
            Task { @MainActor in
                // キー入力の宛先を変えるにはアプリ自体のアクティブ化が要る。
                // AppKit はメインスレッド専用なのでここで行う。
                NSRunningApplication(processIdentifier: pid)?.activate()
                self.noteFocused(id)
            }
        }
    }

    // MARK: - コマンド

    /// ホットキーから呼ばれる。**ツリーを書き換えるだけで、AX 適用は後段に任せる。**
    ///
    /// 連打してもここはメモリ操作で終わり、適用は `FrameScheduler` が
    /// コアレスして最後の状態だけを送る（症状B の対策）。
    public func execute(_ command: Command) {
        // キーが効かないときに「登録されていない」のか「効いたが何も変わらない」のかを
        // 切り分けられるようにする。
        log.trace("コマンド: \(command)")

        switch command {
        case .focus(let direction):
            guard let node = focusedTarget() else { return }
            guard
                let target = TreeOperations.focusTarget(
                    from: node, direction: direction, wrapping: focusWrapping)
            else {
                log.trace("フォーカスの行き先が無い: \(direction.rawValue)")
                return
            }
            focusWindow(target.windowID)

        case .move(let direction):
            // **フローティングは列に居ないので入れ替えられない。** ツリーを触ると
            // 関係のないウィンドウが動く（実際にそうなっていた）。点数で動かす。
            if let floating = focusedFloatingWindow() {
                nudgeFloating(floating, by: direction.offset(points: Self.floatingMoveStep))
                return
            }
            guard let node = focusedTarget(),
                TreeOperations.move(node, direction: direction)
            else { return }
            relayout()

        case .moveBy(let direction, let points):
            // 点数が効くのはフローティングだけ。タイルは i3 と同じく点数を無視して
            // 列の中で入れ替わる。
            if let floating = focusedFloatingWindow() {
                nudgeFloating(floating, by: direction.offset(points: points))
                return
            }
            guard let node = focusedTarget(),
                TreeOperations.move(node, direction: direction)
            else { return }
            relayout()

        case .movePosition(.center):
            guard let floating = focusedFloatingWindow() else {
                log.debug("move position が効くのはフローティングのウィンドウだけ")
                return
            }
            centerFloating(floating)

        case .balanceSizes:
            // `focus parent` で上げていればその中だけ、上げていなければ全体。
            let target: Node = focusedAncestorDepth > 0 ? (focusedTarget() ?? root) : root
            guard TreeOperations.balance(target) else {
                log.debug("分割の比率は既に均等")
                return
            }
            workspaces.active.isLayoutDirty = true
            log.info("分割の比率を均等に戻した")
            relayout()

        case .gaps(let change):
            gaps = change.applied(to: gaps)
            log.info(
                "間隔: 内側 \(Int(gaps.innerHorizontal))x\(Int(gaps.innerVertical)) / "
                    + "外周 上\(Int(gaps.outerTop)) 下\(Int(gaps.outerBottom)) "
                    + "左\(Int(gaps.outerLeft)) 右\(Int(gaps.outerRight))"
                    + "（設定ファイルは書き換えない。読み直すと戻る）")
            workspaces.markAllLayoutsDirty()
            relayout()

        case .moveMouse(let target):
            moveMouse(target)

        case .resize(let dimension, let delta):
            // 点数を比率へ直すには「そのコンテナが配分できる長さ」が要る。
            // `lastLayout` は再配置が非同期なので、直前に木を変えるコマンド
            //（join-with 等）を打たれていると新しいコンテナを知らない。
            // レイアウトは純粋計算なので、ここで作り直すのが確実で安い。
            //
            // **フローティングは分割の境界を持たない。** 境界を探しに行くと関係のない
            // コンテナの比率が動く。自分の寸法を直接変える。
            if let floating = focusedFloatingWindow() {
                resizeFloating(floating, dimension: dimension, delta: delta)
                return
            }
            guard let node = focusedTarget(), let layout = currentLayout(),
                TreeOperations.resize(node, dimension: dimension, delta: delta, layout: layout)
            else { return }
            relayout()

        case .joinWith(let direction):
            guard focusedFloatingWindow() == nil else {
                log.debug("フローティングのウィンドウは join-with の対象にならない")
                return
            }
            guard let node = focusedNode(),
                TreeOperations.joinWith(node, direction: direction)
            else { return }
            relayout()

        case .layout(let arguments):
            applyLayoutCommand(arguments)

        case .workspace(let target):
            switchWorkspace(to: target)

        case .moveNodeToWorkspace(let id):
            moveFocusedWindow(to: id)

        case .closeWindow:
            closeFocusedWindow()

        case .reloadConfig:
            guard let handler = onReloadRequested else {
                log.warn("設定の再読込が配線されていない")
                return
            }
            handler()

        case .fullscreen(let toggle):
            setFullscreen(toggle)

        case .floating(let toggle):
            setFloating(toggle)

        case .exit:
            guard let handler = onExitRequested else {
                log.warn("終了が配線されていない")
                return
            }
            handler()

        case .focusCycle(let target):
            cycleFocus(target)

        case .exec(let line):
            runShell(line)

        case .flattenWorkspaceTree:
            guard TreeOperations.flatten(root) else {
                log.debug("ツリーは既に平ら")
                return
            }
            focusedAncestorDepth = 0
            workspaces.active.isLayoutDirty = true
            log.info("ツリーを平らにした: \(treeDescription)")
            relayout()

        case .focusContainer(let target):
            focusContainer(target)

        case .focusLayer(let layer):
            focusLayer(layer)

        case .split(let target):
            reserveSplit(target)

        case .focusMonitor(let target):
            focusMonitor(target)

        case .moveNodeToMonitor(let target):
            moveFocusedWindowToMonitor(target)

        case .moveWorkspaceToMonitor(let target):
            moveWorkspaceToMonitor(target)

        case .mode(let name):
            guard let handler = onModeRequested else {
                log.warn("モードの切り替えが配線されていない: \(name)")
                return
            }
            handler(name)
        }
    }

    /// キーの層を切り替える要求。`main.swift` が配線する。
    ///
    /// `Engine` はホットキーの登録を知らないので、切り替えそのものは外に任せる。
    public var onModeRequested: (@MainActor (String) -> Void)?

    /// 終了の要求（i3 の `exit`）。`main.swift` が配線する。
    ///
    /// **`Engine` 自身は終わり方を知らない。** 退避したウィンドウを戻し、
    /// 隠したアプリを表示に戻す手順（``prepareForTermination()``）を踏んでから
    /// プロセスを終える必要があり、それは常駐側の仕事。
    public var onExitRequested: (@MainActor () -> Void)?

    // MARK: - モニタ

    /// 指定のモニタを解決する。
    ///
    /// - Returns: 行き先が無い（1台しかない、端で `left`/`right`）なら `nil`。
    private func resolveMonitor(_ target: MonitorTarget) -> MonitorID? {
        let current = workspaces.focusedMonitor
        let ordered = workspaces.monitors
        guard ordered.count > 1 else {
            log.debug("モニタが1台しかないので移動先が無い")
            return nil
        }
        switch target {
        case .next: return workspaces.monitor(offsetFrom: current, by: 1)
        case .previous: return workspaces.monitor(offsetFrom: current, by: -1)
        case .main:
            guard let primary = monitors.primary?.id else { return nil }
            return primary
        case .left, .right:
            // **方向指定は端で巻き戻らない**（i3 と同じ）。巻き戻ると、右端で
            // `right` を押したときに一番左へ飛んで面食らう。
            guard let index = ordered.firstIndex(of: current) else { return nil }
            let next = target == .right ? index + 1 : index - 1
            guard ordered.indices.contains(next) else {
                log.debug("その方向にモニタが無い: \(target.rawValue)")
                return nil
            }
            return ordered[next]
        }
    }

    /// 別のモニタへフォーカスを移す（i3 の `focus output`）。
    private func focusMonitor(_ target: MonitorTarget) {
        guard let monitor = resolveMonitor(target), monitor != workspaces.focusedMonitor else {
            return
        }
        rememberFocus(leaving: workspaces.active)
        guard workspaces.focusMonitor(monitor), let workspace = workspaces[workspaces.activeID]
        else { return }
        log.info("モニタ #\(monitor)（ws\(workspace.id)）へフォーカスを移す")
        notifyVisibleWorkspaces()
        restoreFocus(in: workspace)
    }

    /// フォーカス中のウィンドウを別のモニタへ移す（i3 の `move container to output`）。
    ///
    /// 行き先はそのモニタが**今映しているワークスペース**。移したウィンドウを
    /// 追いかけてフォーカスも移る（i3 と同じ）。
    private func moveFocusedWindowToMonitor(_ target: MonitorTarget) {
        guard let monitor = resolveMonitor(target),
            let destination = workspaces.shown(on: monitor),
            let windowID = focusedWindowOnActiveWorkspace(),
            let record = registry[windowID], record.workspace != destination
        else { return }

        registry.update(windowID) { $0.workspace = destination }
        workspaces[record.workspace]?.isLayoutDirty = true
        workspaces[destination]?.isLayoutDirty = true
        workspaces[destination]?.lastFocused = windowID
        // 退避先の記録は捨てる。別のモニタへ出す時点で位置は作り直しになる。
        stashedFrames.removeValue(forKey: windowID)
        toleratedFrames.removeValue(forKey: windowID)
        // **学習した最小寸法は残す。** モニタが変わってもアプリの下限は変わらない。
        log.info("[\(windowID)] をモニタ #\(monitor)（ws\(destination)）へ移した")
        workspaces.focusMonitor(monitor)
        pendingFocusRestore = destination
        notifyVisibleWorkspaces()
        relayout()
    }

    /// 今のワークスペースを別のモニタへ移す（i3 の `move workspace to output`）。
    ///
    /// 相手のモニタが映していたワークスペースは入れ替わりにこちらへ来る。
    private func moveWorkspaceToMonitor(_ target: MonitorTarget) {
        guard let monitor = resolveMonitor(target) else { return }
        let moving = workspaces.activeID
        let swapped = workspaces.shown(on: monitor)
        guard workspaces.moveActiveWorkspace(to: monitor) else { return }
        // どちらのワークスペースも領域が変わるので、寸法を再適用する。
        workspaces[moving]?.isLayoutDirty = true
        if let swapped { workspaces[swapped]?.isLayoutDirty = true }
        log.info(
            "ws\(moving) をモニタ #\(monitor) へ移した"
                + (swapped.map { "（ws\($0) と入れ替え）" } ?? ""))
        notifyVisibleWorkspaces()
        relayout()
    }

    /// コンテナを選ぶ上下移動（i3 の `focus parent` / `focus child`）。
    ///
    /// 選んでいる範囲は枠線で見えるようにする。見えないと何を動かすのか分からない。
    private func focusContainer(_ target: ContainerFocus) {
        guard let window = focusedNode() else { return }
        switch target {
        case .parent:
            // ルートまで。ルートを選べば `layout` でワークスペース全体の向きを変えられる。
            guard focusedAncestorDepth < window.ancestors.count else {
                log.debug("これ以上上のコンテナが無い")
                return
            }
            focusedAncestorDepth += 1
        case .child:
            guard focusedAncestorDepth > 0 else {
                log.debug("すでにウィンドウを選んでいる")
                return
            }
            focusedAncestorDepth -= 1
        }
        log.debug(
            "フォーカスの階層: \(focusedAncestorDepth) → \(focusedTarget()?.description ?? "?")")
        notifyFocusedFrame()
    }

    /// タイルとフローティングの間でフォーカスを移す
    ///（i3 の `focus mode_toggle` / `focus floating` / `focus tiling`）。
    ///
    /// 行き先は**その層で最後に使ったウィンドウ**。番号順にすると、浮かせた
    /// ウィンドウが増えたときに毎回別のものへ飛ぶ。
    private func focusLayer(_ layer: FocusLayer) {
        guard let current = focusedWindowOnActiveWorkspace(), let record = registry[current]
        else { return }
        let wantsFloating = layer.wantsFloating ?? !record.disposition.isFloating
        guard wantsFloating != record.disposition.isFloating else {
            log.trace("既にその層に居る")
            return
        }
        let candidates = registry.visibleIDs(in: workspaces.activeID).filter {
            registry[$0]?.disposition.isFloating == wantsFloating
        }
        guard
            let target = candidates.max(by: {
                (registry[$0]?.lastFocusedAt ?? 0) < (registry[$1]?.lastFocusedAt ?? 0)
            })
        else {
            log.debug(wantsFloating ? "フローティングのウィンドウが無い" : "タイルのウィンドウが無い")
            return
        }
        focusWindow(target)
    }

    /// 次に開くウィンドウの入り方を予約する（i3 の `split h` / `split v`）。
    private func reserveSplit(_ target: SplitTarget) {
        guard let id = focusedWindowOnActiveWorkspace(), let node = root.findWindow(id) else {
            return
        }
        let orientation: Orientation
        switch target {
        case .horizontal: orientation = .horizontal
        case .vertical: orientation = .vertical
        case .opposite: orientation = (node.parent?.orientation ?? .horizontal).flipped
        }
        pendingSplit = (windowID: id, orientation: orientation)
        log.info("[\(id)] の次のウィンドウは \(orientation.rawValue) に分けて入れる")
    }

    /// シェルへ渡して実行する。**待たない。**
    ///
    /// i3 の `exec`。`$mod+Return` でターミナルを開くのが i3 の基本操作なので、
    /// これが無いと常用の起点が作れない。
    ///
    /// - Important: **終了を待ってはいけない。** 待つとホットキーの配送が止まる。
    ///   標準入出力は捨てる（繋いだままにすると、出力を読まない相手が
    ///   パイプを埋めた時点で止まる）。
    private func runShell(_ line: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // 参照を残さないと、終了を待つ前に解放されてゾンビが残りうる。
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.launchedProcesses.removeAll { $0 === finished }
            }
        }
        do {
            try process.run()
            launchedProcesses.append(process)
            log.info("exec: \(line)（pid=\(process.processIdentifier)）")
        } catch {
            log.error("exec に失敗した: \(line): \(error)")
        }
    }

    /// アプリ巡回・アプリ内のウィンドウ巡回。
    ///
    /// **押し続けている間は並びを組み直さない**（`FocusCycler.Session`）。
    /// フォーカスすると最近使った順が変わるので、毎回組み直すと2つのアプリの間を
    /// 往復するだけになる。
    private func cycleFocus(_ target: FocusCycleTarget) {
        let candidates = focusCycleCandidates()
        guard !candidates.isEmpty else {
            log.debug("巡回できるウィンドウが無い")
            return
        }

        let next: CGWindowID?
        if target.isAcrossApps {
            // **これは「組み直した場合の並び」で、実際に使う並びとは違う。**
            // 続きが有効なら押し始めた時点の並びが使われる（そこが肝なので、
            // この行だけを見て「毎回組み直している」と誤読しないこと）。
            log.trace("巡回の候補（最近使った順）: \(FocusCycler.appOrder(candidates))")
            next = focusCycleSession.advance(
                order: FocusCycler.appOrder(candidates),
                now: ProcessInfo.processInfo.systemUptime,
                resetAfter: focusCycleReset, forward: target.isForward)
        } else {
            // アプリ内は固定の輪なので、今の位置から進めれば足りる。
            guard let pid = focusedWindowID.flatMap({ registry[$0]?.pid }) else { return }
            next = FocusCycler.next(
                in: FocusCycler.windowsInApp(candidates, pid: pid),
                from: focusedWindowID, forward: target.isForward)
        }

        guard let next else {
            log.debug("巡回の行き先が無い: \(target.rawValue)")
            return
        }
        log.debug("巡回: \(target.rawValue) → [\(next)]")
        focusWindow(next)
    }

    /// 巡回の候補。
    ///
    /// **画面に出ているものだけ**を対象にする。非表示ワークスペースのウィンドウを
    /// 含めると、巡回のたびにワークスペースが飛んで収拾がつかない
    /// （`focus-follows-activation` が働くため）。設定で全体にもできる。
    private func focusCycleCandidates() -> [FocusCycler.Candidate] {
        registry.allIDs.compactMap { id in
            guard let record = registry[id] else { return nil }
            // ダイアログ等は対象外。サブディスプレイのウィンドウは画面に出ているので含める。
            guard record.disposition.isTiled || record.disposition.isFloating
                || record.disposition.isOnOtherMonitor
            else { return nil }
            if focusCycleScope == .activeWorkspace, !record.disposition.isOnOtherMonitor,
                !workspaces.isVisible(record.workspace)
            {
                return nil
            }
            return FocusCycler.Candidate(
                id: id, pid: record.pid, lastFocusedAt: record.lastFocusedAt)
        }
    }

    // MARK: - フローティングのウィンドウ

    /// キーボードで動かすときの1回の量。
    ///
    /// i3 の既定（10px）より大きくしてある。comet では `move` を押しっぱなしにしても
    /// 繰り返さないので、1回で見て分かるだけ動かないと使えない。
    /// 細かく決めたいときは `move left 10 px` と点数を書く。
    private static let floatingMoveStep: CGFloat = 50

    /// コマンドの対象がフローティングのウィンドウなら、その ID。
    ///
    /// **タイル用の経路と分ける必要がある。** フローティングはツリーに居ないので、
    /// `focusedNode()` は「最後にフォーカスしたタイルの葉」を返してしまう。
    /// それを対象にすると、浮いているウィンドウを選んでいるのに**別のウィンドウが
    /// 動く**（実際にそうなっていた）。
    private func focusedFloatingWindow() -> CGWindowID? {
        guard let id = focusedWindowOnActiveWorkspace(),
            registry[id]?.disposition.isFloating == true
        else { return nil }
        return id
    }

    /// フローティングのウィンドウの今の矩形。
    ///
    /// 配置計算の対象外なので `desiredFrames` には無い。実測値が唯一の手がかり。
    private func floatingFrame(of id: CGWindowID) -> CGRect? {
        guard let frame = registry[id]?.observedFrame, frame.width > 0, frame.height > 0 else {
            log.debug("[\(id)] の矩形が分からないので動かせない")
            return nil
        }
        return frame
    }

    /// フローティングのウィンドウを動かす。
    private func nudgeFloating(_ id: CGWindowID, by delta: CGSize) {
        guard let frame = floatingFrame(of: id) else { return }
        let moved = frame.offsetBy(dx: delta.width, dy: delta.height)
        applyFloatingFrame(id, moved, setSize: false)
    }

    /// フローティングのウィンドウを今のモニタの中央へ（i3 の `move position center`）。
    private func centerFloating(_ id: CGWindowID) {
        guard let frame = floatingFrame(of: id) else { return }
        guard let area = floatingArea(for: frame) else { return }
        let centered = CGRect(
            x: area.midX - frame.width / 2, y: area.midY - frame.height / 2,
            width: frame.width, height: frame.height)
        applyFloatingFrame(id, centered, setSize: false)
    }

    /// フローティングのウィンドウの寸法を変える。
    ///
    /// **左上を固定して広げる。** 分割の境界を持たないので、隣に譲らせる余地が無い。
    private func resizeFloating(_ id: CGWindowID, dimension: Dimension, delta: CGFloat) {
        guard let frame = floatingFrame(of: id) else { return }
        // 潰れて呼び戻せなくなるのを防ぐ下限。アプリ自身の最小寸法はこれより
        // 大きいことが多いので、そちらに当たれば実測がそこで止まるだけ。
        let floor: CGFloat = 100
        var resized = frame
        switch dimension {
        case .width:
            resized.size.width = max(floor, frame.width + delta)
        case .height:
            resized.size.height = max(floor, frame.height + delta)
        }
        applyFloatingFrame(id, resized, setSize: true)
    }

    /// フローティングのウィンドウを収める領域。
    private func floatingArea(for frame: CGRect) -> CGRect? {
        (monitors.owner(of: frame) ?? focusedMonitor)?.visibleFrame
    }

    /// フローティングのウィンドウへ矩形を流し込む。
    ///
    /// **`desiredFrames` には入れない。** 入れると見張りが「ずれている」と判断して
    /// 掴んで動かすたびに引き戻しに来る。フローティングは利用者のものにしておく。
    private func applyFloatingFrame(_ id: CGWindowID, _ frame: CGRect, setSize: Bool) {
        // 画面の外へ出すと呼び戻せない。モニタの中へ押し込む。
        let clamped = floatingArea(for: frame).map { Geometry.clamped(frame, within: $0) } ?? frame
        registry.update(id) { $0.observedFrame = clamped }
        // 退避先から戻す位置も更新する。覚え直さないと、ワークスペースを往復した
        // ときに動かす前の位置へ跳ね返る。
        if stashedFrames[id] != nil { stashedFrames[id] = clamped }
        scheduler.reapply(id, TargetFrame(rect: clamped, setSize: setSize))
        // 枠線は AX の適用を待たずに動かす。待つと操作が鈍く見える。
        notifyFocusedFrame(measured: (id: id, frame: clamped))
        log.debug("[\(id)] を \(Geometry.rendered(clamped)) へ動かした（フローティング）")
    }

    // MARK: - フォーカスをポインタに追従させる

    /// 自分でポインタを飛ばした直後は反応しない猶予。
    ///
    /// `move-mouse` は「フォーカス中のウィンドウの中央へ」飛ばす。追従が反応すると
    /// **飛ばした先のウィンドウをフォーカスし直す**ので、フォーカスとポインタが
    /// 互いを追いかけ続ける。
    private static let mouseWarpGrace: TimeInterval = 0.3

    private var mouseMonitor: Any?
    private var lastMouseWarpAt: TimeInterval = 0
    /// 直前に判定した位置。同じ場所の通知に何度も反応しない。
    private var lastMousePoint: CGPoint?

    private func startMouseTracking() {
        guard mouseMonitor == nil, !isDryRun else { return }
        // `CGEventTap` ではなく大域モニタを使う。**入力監視の権限を増やさない**ため。
        // アクセシビリティ権限だけで受け取れる。
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        log.info("focus-follows-mouse: 有効（ポインタが乗ったウィンドウへフォーカスを移す）")
    }

    private func stopMouseTracking() {
        guard let monitor = mouseMonitor else { return }
        NSEvent.removeMonitor(monitor)
        mouseMonitor = nil
        lastMousePoint = nil
        log.info("focus-follows-mouse: 無効")
    }

    private func pointerMoved() {
        guard focusFollowsMouse else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMouseWarpAt > Self.mouseWarpGrace else { return }
        // **掴んでいる間は動かさない。** ドラッグで他のウィンドウを跨ぐたびに前面が
        // 変わると、掴んだものが後ろへ回って操作にならない。
        guard !isUserDragging() else { return }

        let point = Geometry.toAX(
            CGRect(origin: NSEvent.mouseLocation, size: .zero),
            primaryMaxY: MonitorManager.primaryMaxY
        ).origin
        if let last = lastMousePoint, abs(last.x - point.x) < 1, abs(last.y - point.y) < 1 {
            return
        }
        lastMousePoint = point

        guard let target = managedWindow(at: point), target != focusedWindowID else { return }
        log.trace("focus-follows-mouse: [\(target)] へ移す")
        focusWindow(target)
    }

    /// その点にあるウィンドウ。
    ///
    /// **AX にも `CGWindowList` にも問い合わせない。** 追従はポインタが動くたびに
    /// 判定するので、1回でも往復を挟むと常駐コストが跳ね上がる。既に持っている
    /// 目標矩形（タイル）と実測矩形（フローティング）だけで決める。
    ///
    /// 重なりの順序は「全画面 → フローティング → タイル」。タイルは互いに重ならない。
    private func managedWindow(at point: CGPoint) -> CGWindowID? {
        var floatingHit: CGWindowID?
        var tiledHit: CGWindowID?
        for pair in workspaces.visiblePairs {
            // 全画面のウィンドウは他を覆っているので、含まれていれば即座に決まる。
            if let full = pair.workspace.fullscreenWindowID,
                desiredFrames[full]?.contains(point) == true
            {
                return full
            }
            for id in registry.visibleIDs(in: pair.workspace.id) {
                guard let record = registry[id] else { continue }
                if record.disposition.isFloating {
                    guard record.observedFrame?.contains(point) == true else { continue }
                    floatingHit = id
                } else if record.disposition.isTiled {
                    guard desiredFrames[id]?.contains(point) == true else { continue }
                    tiledHit = id
                }
            }
        }
        return floatingHit ?? tiledHit
    }

    // MARK: - マウスポインタ

    /// マウスポインタを動かす（AeroSpace の `move-mouse`）。
    ///
    /// **フォーカスを追ってポインタが飛ぶのは煩わしい**ので、既定のバインドには
    /// 入れない。「ポインタがどこかへ行ってしまった」ときの呼び戻しに使う。
    private func moveMouse(_ target: MouseTarget) {
        let area: CGRect?
        if target.isWindow {
            area = focusedWindowOnActiveWorkspace().flatMap {
                desiredFrames[$0] ?? registry[$0]?.observedFrame
            }
        } else {
            area = focusedMonitor?.visibleFrame
        }
        guard let area, area.width > 0, area.height > 0 else {
            log.debug("move-mouse の行き先が分からない")
            return
        }
        // 既に中に居るなら動かさない（lazy）。
        let current = Geometry.toAX(
            CGRect(origin: NSEvent.mouseLocation, size: .zero),
            primaryMaxY: MonitorManager.primaryMaxY
        ).origin
        if target.isLazy, area.contains(current) {
            log.trace("move-mouse: 既に範囲の中に居るので動かさない")
            return
        }
        let center = CGPoint(x: area.midX, y: area.midY)
        // CGWarpMouseCursorPosition はグローバル座標（左上原点）を取る。
        lastMouseWarpAt = ProcessInfo.processInfo.systemUptime
        CGWarpMouseCursorPosition(center)
        // ワープでは移動イベントが出ないため、ホバーの状態が更新されない。
        // 関連付けを一度切って戻すと macOS が現在位置を作り直す。
        CGAssociateMouseAndMouseCursorPosition(1)
        log.debug("マウスポインタを (\(Int(center.x)), \(Int(center.y))) へ動かした")
    }

    /// フォーカス中のウィンドウを領域いっぱいに広げる／戻す。
    ///
    /// ツリーは変えない。**覆うだけ**なので、解除すると元の配置がそのまま出てくる。
    private func setFullscreen(_ toggle: Toggle) {
        guard let id = focusedWindowOnActiveWorkspace() else { return }
        let workspace = workspaces.active
        // **フローティングは覆えない。** 配置計算の対象外なので目標矩形を持たず、
        // 全画面の矩形を当てる先が無い。黙って無反応にすると壊れたように見えるので、
        // 何をすればよいかまで伝える。
        guard registry[id]?.disposition.isFloating != true else {
            log.info(
                "[\(id)] はフローティングなので全画面にできない"
                    + "（`floating disable` でタイルに戻すと広げられる）")
            return
        }
        let isFullscreen = workspace.fullscreenWindowID == id
        guard toggle.resolve(current: isFullscreen) != isFullscreen else {
            log.trace("全画面の状態は既に指定どおり")
            return
        }
        if isFullscreen {
            workspace.fullscreenWindowID = nil
            log.info("[\(id)] の全画面を解除した")
        } else {
            workspace.fullscreenWindowID = id
            log.info("[\(id)] を全画面にした")
        }
        // 全画面の切り替えは寸法が変わるので、位置だけの再適用では足りない。
        workspace.isLayoutDirty = true
        relayout()
    }

    /// フォーカス中のウィンドウを閉じる。
    ///
    /// 破棄の通知（`AXUIElementDestroyed`）で台帳から外れるので、ここでは再配置しない。
    private func closeFocusedWindow() {
        guard let id = focusedWindowOnActiveWorkspace(),
            let element = elements[id], let pid = registry[id]?.pid
        else { return }

        let title = registry[id]?.title?.prefix(40) ?? "?"
        applierPool.queue(for: pid).async {
            let closed = AXBridge.close(element.raw)
            Task { @MainActor in
                if closed {
                    self.log.info("[\(id)] \(title) を閉じた")
                } else {
                    self.log.warn("[\(id)] \(title) を閉じられなかった（閉じるボタンが無い）")
                }
            }
        }
    }

    /// 設定を読み直す要求。`main.swift` が配線する。
    ///
    /// `Engine` は設定ファイルの形式を知らないので、読み直しそのものは外に任せる。
    public var onReloadRequested: (@MainActor () -> Void)?

    /// 設定が変わったことを伝える。**ツリーの形は保つ。**
    ///
    /// gaps や既定の向きが変われば寸法が変わるので、全ワークスペースに
    /// サイズの再適用を要求する。
    public func configurationChanged() {
        workspaces.markAllLayoutsDirty()
        relayout()
    }

    // MARK: - ワークスペース

    /// 表示するワークスペースを切り替える。
    ///
    /// **AX の適用は再配置に任せる。** ここで直接動かすと、
    /// `["move-node-to-workspace 3", "workspace 3"]` のような複数コマンドで
    /// 中間状態が画面に出てしまう。再配置は1回にまとめられるので1フレームで完了する。
    public func switchWorkspace(to target: WorkspaceTarget) {
        guard let id = resolveWorkspace(target) else { return }
        let outgoing = workspaces.active
        // 追従を止める猶予の起点。**実際に切り替わる場合だけ**控える
        //（`alreadyActive` で止めると、押しただけで追従が鈍る）。
        if id != workspaces.activeID {
            lastWorkspaceSwitchAt = ProcessInfo.processInfo.systemUptime
        }

        switch workspaces.activate(id) {
        case .unknown:
            return

        case .alreadyActive:
            // **同じ番号をもう一度押したら直前へ戻る**（i3 の
            // `workspace_auto_back_and_forth`）。番号を押し間違えたときの
            // 取り消しにもなる。番号を明示した場合だけ効かせる。
            guard workspaceAutoBackAndForth, case .index = target,
                let previous = workspaces.previousID, previous != id
            else { return }
            log.debug("ワークスペース \(id) は既に表示中なので直前の \(previous) へ戻る")
            switchWorkspace(to: .index(previous))
            return

        case .focusedOtherMonitor(let monitor):
            // **既に別のモニタに映っているなら、フォーカスを移すだけ。**
            // ウィンドウを動かすと、そのモニタで作業していた配置が壊れる（i3 と同じ扱い）。
            rememberFocus(leaving: outgoing)
            log.info("ワークスペース \(id) は別のモニタ #\(monitor) に映っているのでそちらへ移る")
            pendingFocusRestore = id
            notifyVisibleWorkspaces()
            relayout()

        case .replaced(let monitor, let outgoingID):
            rememberFocus(leaving: outgoing)
            restoringWorkspaces.insert(id)
            log.info("モニタ #\(monitor): ワークスペース \(outgoingID) → \(id)")
            // 壁紙とインジケータはウィンドウ移動より先に。どちらも自プロセス側なので
            // 即座に終わり、切替が速く見える（症状D）。
            notifyVisibleWorkspaces()
            // フォーカスは**再配置のあと**に戻す。先に戻すと、まだ退避先にいる
            // ウィンドウをアクティブにしてしまい「アプリは前面だが見えない」状態になる。
            pendingFocusRestore = id
            // **ここは `immediately: true` にしない。** 「移動 + 切替」のように1つの
            // バインドで複数コマンドを撃つとき、まとめて1回の再配置にすることで
            // 中間状態が画面に出ない。
            relayout()
        }
    }

    /// 直前にワークスペースを切り替えた時刻（`systemUptime`）。
    ///
    /// これより後の短い間は、アクティブ化への追従を止める
    ///（``followActivationIfNeeded(_:)`` を見ること）。
    private var lastWorkspaceSwitchAt: TimeInterval = 0

    /// 切替のあと、アクティブ化への追従を止めておく時間。
    ///
    /// **アプリを隠すのは非同期**で、macOS が前面を選び直すまでに数十 ms かかる
    ///（実測 39ms）。それより十分に長く、かつ利用者の次の操作を邪魔しない長さ。
    private static let activationFollowGrace: TimeInterval = 0.5

    /// 離脱側のフォーカスを保存する。戻ってきたときにここへ返す。
    ///
    /// 他のワークスペースのウィンドウを覚えても意味がないので絞る
    ///（focus-follows-activation ではこの状況が普通に起きる）。
    private func rememberFocus(leaving workspace: Workspace) {
        guard let focused = focusedWindowID, registry[focused]?.workspace == workspace.id else {
            return
        }
        workspace.lastFocused = focused
    }

    /// モニタ構成の変化を割り当てへ反映する。
    ///
    /// **消えたモニタが映していたワークスペースは退避される。** 割り当てを直さないと
    /// 「どのモニタにも映っていないのに退避もされない」ウィンドウが画面に残る。
    private func syncMonitorAssignment() {
        let ids = managesAllMonitors
            ? monitors.monitors.map(\.id)
            : monitors.primary.map { [$0.id] } ?? []
        guard workspaces.reassign(monitors: ids) else { return }
        log.info("モニタとワークスペースの割り当て: \(visibleAssignmentDescription)")
        notifyVisibleWorkspaces()
    }

    private var visibleAssignmentDescription: String {
        workspaces.visiblePairs.map { "#\($0.monitor)=ws\($0.workspace.id)" }
            .joined(separator: " ")
    }

    /// ワークスペースの見え方を伝える。壁紙とインジケータの更新に使う。
    private func notifyVisibleWorkspaces() {
        guard let handler = onWorkspaceStatusChanged else { return }
        let status = workspaceStatus
        lastNotifiedStatus = status
        handler(status)
    }

    /// 中身の増減も含めて、変わっていたら伝える。
    ///
    /// ウィンドウを開いた・閉じた・別の番号へ移したときも「どの番号に居るか」の
    /// 表示は変わる。切替のときだけ伝えていると、バーの表示が実態から遅れる。
    private func notifyVisibleWorkspacesIfChanged() {
        guard onWorkspaceStatusChanged != nil, workspaceStatus != lastNotifiedStatus else { return }
        notifyVisibleWorkspaces()
    }

    private var lastNotifiedStatus: WorkspaceStatus?

    /// ワークスペースの見え方。
    public var workspaceStatus: WorkspaceStatus {
        WorkspaceStatus(
            visible: workspaces.visiblePairs.map {
                MonitorAssignment(monitor: $0.monitor, workspace: $0.workspace.id)
            },
            focused: workspaces.activeID,
            occupied: occupiedWorkspaces,
            total: workspaces.count)
    }

    /// ウィンドウが1枚以上あるワークスペース。
    ///
    /// 数えるのは**並べる対象と浮かせたもの**だけ。ダイアログや最小化されたものを
    /// 数えると、閉じても番号が消えずに実態とずれる。
    public var occupiedWorkspaces: Set<WorkspaceID> {
        var result: Set<WorkspaceID> = []
        for id in registry.allIDs {
            guard let record = registry[id],
                record.disposition.isTiled || record.disposition.isFloating
            else { continue }
            result.insert(record.workspace)
        }
        return result
    }

    /// フォーカスのあるモニタを、フォーカス中のウィンドウに合わせる。
    ///
    /// **これが無いと、2画面でコマンドの対象が読めなくなる。** 右の画面のウィンドウを
    /// クリックしたのに、コマンドが左の画面のワークスペースへ効いてしまう。
    private func followFocusedMonitor(_ id: CGWindowID) {
        guard let workspace = registry[id]?.workspace,
            let monitor = workspaces.monitor(showing: workspace),
            workspaces.focusMonitor(monitor)
        else { return }
        log.trace("フォーカスのあるモニタ: #\(monitor)")
        notifyVisibleWorkspaces()
    }

    /// `workspace` / `move-node-to-workspace` の行き先を番号に直す。
    ///
    /// - Returns: 行けない指定（範囲外、戻る先が無い）なら `nil`。理由はログに残す。
    private func resolveWorkspace(_ target: WorkspaceTarget) -> WorkspaceID? {
        switch target {
        case .index(let id):
            guard workspaces[id] != nil else {
                log.warn("ワークスペース \(id) は存在しない（1〜\(workspaces.count)）")
                return nil
            }
            return id
        case .backAndForth:
            guard let previous = workspaces.previousID else {
                log.debug("戻る先のワークスペースがまだ無い")
                return nil
            }
            return previous
        case .next, .previous:
            let offset = target == .next ? 1 : -1
            // **空のワークスペースは飛ばす**（i3 の `workspace next` と同じ）。
            // 飛ばさないと、使っていない番号を何度も通過することになる。
            guard
                let id = workspaces.occupiedID(
                    offsetFrom: workspaces.activeID, by: offset, occupied: occupiedWorkspaces)
            else {
                log.debug("中身のある他のワークスペースが無い")
                return nil
            }
            return id
        }
    }

    /// フォーカス中のウィンドウを別のワークスペースへ移す。表示は切り替えない。
    ///
    /// `next` / `prev` は**番号順**（空のワークスペースも飛ばさない）。
    /// 移動は「今の場所から出す」のが目的なので、空いている番号へ出せるほうがよい。
    /// 一方 `workspace next` は「行った先に何かある」ほうがよいので空を飛ばす。
    public func moveFocusedWindow(to target: WorkspaceTarget) {
        let resolved: WorkspaceID?
        switch target {
        case .next: resolved = workspaces.id(offsetFrom: workspaces.activeID, by: 1)
        case .previous: resolved = workspaces.id(offsetFrom: workspaces.activeID, by: -1)
        default: resolved = resolveWorkspace(target)
        }
        guard let id = resolved else { return }
        guard let windowID = focusedWindowOnActiveWorkspace(),
            let record = registry[windowID], record.workspace != id
        else { return }

        registry.update(windowID) { $0.workspace = id }
        // 移動元と移動先はどちらも並びが変わる。復帰時にサイズを適用し直す。
        workspaces[record.workspace]?.isLayoutDirty = true
        workspaces[id]?.isLayoutDirty = true
        // **移した先で選ばれるようにしておく。** `["move-node-to-workspace 3",
        // "workspace 3"]` のような組み合わせでは、切替後のフォーカス復元が
        // 移動先の記録を見る。書き換えないと、せっかく持って行ったウィンドウとは
        // 別のものが選ばれて追従したように見えない。
        workspaces[id]?.lastFocused = windowID

        // 移した先が非表示なら、フォーカスは表示中のワークスペースへ戻す。
        // 画面から消えたウィンドウにフォーカスが残ると、キー入力の宛先が見えなくなる。
        if id != workspaces.activeID, focusedWindowID == windowID {
            focusedWindowID = nil
            pendingFocusRestore = workspaces.activeID
        }
        log.info("[\(windowID)] をワークスペース \(record.workspace) → \(id) へ移した")
        relayout()
    }

    /// ワークスペースのフォーカスを復元する。
    ///
    /// 離脱時に覚えたウィンドウが残っていればそこへ、無ければ先頭のウィンドウへ。
    /// どちらも無ければフォーカスは持たない。
    private func restoreFocus(in workspace: Workspace) {
        let remembered = workspace.lastFocused.flatMap { id -> CGWindowID? in
            guard registry[id]?.workspace == workspace.id else { return nil }
            return id
        }
        // 覚えが無ければ**並びの先頭**へ。台帳の登録順ではなくツリーの順にするのは、
        // 「左上のウィンドウにフォーカスが行く」ほうが予測しやすいため。
        let first = workspace.root.windowIDs.first ?? registry.visibleIDs(in: workspace.id).first
        guard let target = remembered ?? first else {
            focusedWindowID = nil
            log.debug("ワークスペース \(workspace.id) にフォーカスできるウィンドウが無い")
            return
        }
        focusWindow(target)
    }

    /// フォーカスのあるモニタ。割り当てが崩れていればプライマリに落とす。
    private var focusedMonitor: MonitorManager.Monitor? {
        monitors.monitor(id: workspaces.focusedMonitor) ?? monitors.primary
    }

    /// 今のツリーに対するレイアウト。**副作用は無い**ので必要なときに作り直せる。
    private func currentLayout() -> LayoutEngine.Result? {
        guard let monitor = focusedMonitor, !root.isEmpty else { return nil }
        return LayoutEngine.compute(
            root: root, area: monitor.visibleFrame, gaps: gaps, scale: monitor.scale,
            minimums: minimumSizes)
    }

    private func applyLayoutCommand(_ arguments: [LayoutArgument]) {
        if arguments.togglesFloating {
            toggleFloating()
            return
        }

        // `tiles` を含む指定は「まずタイルであること」を求める。フローティング中なら
        // 戻すのが先で、向きの巡回は次の押下から（AeroSpace の「今と違う最初の状態に
        // する」という巡回の考え方に合わせる）。
        if arguments.contains(.tiles), let id = focusedWindowOnActiveWorkspace(),
            registry[id]?.disposition.isFloating == true
        {
            floatingWindows.remove(id)
            registry.update(id) { $0.disposition = .tiled }
            // **寸法の再適用を要求する。** 切替直後は位置だけを送る最適化が効いており、
            // 要求しないとフローティング時の寸法のままタイルの位置へ置かれる。
            workspaces.active.isLayoutDirty = true
            log.info("[\(id)] をタイルに戻した")
            relayout()
            return
        }

        let candidates = arguments.orientations
        guard !candidates.isEmpty else {
            log.warn("layout の引数に向きが無い: \(arguments.map(\.rawValue).joined(separator: " "))")
            return
        }
        guard let node = focusedTarget(),
            TreeOperations.cycleOrientation(of: node, among: candidates)
        else { return }
        relayout()
    }

    /// フローティングにする／タイルへ戻す（i3 の `floating enable|disable|toggle`）。
    private func setFloating(_ toggle: Toggle) {
        guard let id = focusedWindowOnActiveWorkspace(), let record = registry[id] else { return }
        let isFloating = record.disposition.isFloating
        guard toggle.resolve(current: isFloating) != isFloating else {
            log.trace("フローティングの状態は既に指定どおり")
            return
        }
        toggleFloating()
    }

    /// タイル配置とフローティングを切り替える。
    ///
    /// 管理対象外のウィンドウ（ダイアログなど）は対象にしない。掴んでも困るだけ。
    private func toggleFloating() {
        // フローティング中のウィンドウはツリーに居ないので、`focusedNode()` では引けない。
        // 実際にフォーカスされている ID を先に見る。
        guard let id = focusedWindowOnActiveWorkspace(), let record = registry[id] else { return }

        switch record.disposition {
        case .tiled:
            floatingWindows.insert(id)
            registry.update(id) { $0.disposition = .floating }
            log.info("[\(id)] をフローティングにした")
        case .floating:
            floatingWindows.remove(id)
            registry.update(id) { $0.disposition = .tiled }
            log.info("[\(id)] をタイルに戻した")
            workspaces.active.isLayoutDirty = true
        case .unmanaged(let reason):
            log.debug("[\(id)] は管理対象外（\(reason)）なので切り替えない")
            return
        }
        relayout()
    }

    /// 生成通知を受けたウィンドウを取り込む。
    ///
    /// - Important: **一度の失敗で諦めてはいけない。** 生まれた直後の AX 要素は
    ///   ウィンドウ ID も属性も返さないことがある（ブラウザや Electron 製アプリで
    ///   起きる）。ここで諦めると、そのウィンドウには個別通知も張られないので
    ///   移動・破棄の通知も来ず、**以後どの経路からも拾えない**。少し待って
    ///   試し直す。それでも駄目なら見張りの拾い直し（``adoptMissingWindows``）に任せる。
    private func adoptWindow(_ element: AXElement, pid: pid_t, attempt: Int = 1) {
        applierPool.queue(for: pid).async {
            let id = AXPrivate.windowID(of: element.raw)
            let attributes = AXBridge.readWindowAttributes(element.raw)
            Task { @MainActor in
                guard let id, let attributes else {
                    guard attempt < Self.maxAdoptionAttempts else {
                        self.log.debug(
                            "生成通知のウィンドウを \(attempt) 回試しても読めなかった pid=\(pid)。"
                                + "見張りの拾い直しに任せる")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.adoptionRetryDelay) {
                        MainActor.assumeIsolated {
                            self.adoptWindow(element, pid: pid, attempt: attempt + 1)
                        }
                    }
                    return
                }
                let discovered = DiscoveredWindow(
                    id: id, element: element, attributes: attributes)
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                // 新しいウィンドウの初回配置は待たせない。**症状A の対策。**
                // 適用順の先頭に回し、次のランループを待たずにその場で配置する。
                self.priorityWindows.insert(id)
                // **新しく開いたウィンドウは今いるモニタへ。** アプリが決めた初期位置
                // （多くはメイン画面の中央）に従うと、右の画面で作業していても
                // 左に出てきてしまう。i3 も focused output に開く。
                self.register(
                    [discovered], pid: pid, bundleID: bundleID, immediately: true,
                    placement: .focusedMonitor)
            }
        }
    }

    /// 生成通知を取りこぼしたときに試し直す回数と間隔。
    ///
    /// 実測では 1 回目で読めることが多く、読めない場合も 100ms 待てば揃う。
    /// 上限を置くのは、閉じられたウィンドウを延々と追わないため。
    private static let maxAdoptionAttempts = 4
    private static let adoptionRetryDelay: TimeInterval = 0.1

    /// アプリのウィンドウを走査し直す。**冪等。** 既知のウィンドウは所属も
    /// フォーカス履歴も保たれる（``register(_:pid:bundleID:immediately:)`` 参照）。
    private func rescan(pid: pid_t) {
        guard let application = observerHub.application(for: pid) else { return }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        applierPool.queue(for: pid).async {
            let scan = AXBridge.scanWindows(of: application.raw)
            Task { @MainActor in
                self.register(scan.windows, pid: pid, bundleID: bundleID)
            }
        }
    }

    private func refreshWindow(_ element: AXElement, pid: pid_t) {
        applierPool.queue(for: pid).async {
            guard let id = AXPrivate.windowID(of: element.raw),
                let attributes = AXBridge.readWindowAttributes(element.raw)
            else { return }
            Task { @MainActor in
                guard let record = self.registry[id] else { return }
                let frame = attributes.position.map {
                    CGRect(origin: $0, size: attributes.size ?? .zero)
                }
                let disposition = self.resolveDisposition(
                    WindowClassifier.classify(
                        WindowSnapshot(
                            role: attributes.role,
                            subrole: attributes.subrole,
                            isFullScreen: attributes.isFullScreen,
                            isMinimized: attributes.isMinimized,
                            size: attributes.size ?? .zero,
                            layer: ScreenWindows.layer(of: id))),
                    id: id, pid: pid, bundleID: record.bundleID, title: attributes.title,
                    frame: frame)
                self.registry.update(id) { $0.disposition = disposition }
                self.relayout()
            }
        }
    }

    /// 外部からウィンドウが動かされたときの入口。
    ///
    /// 通知は「動いた」ことしか伝えないので、実際の矩形を読んでから判断する。
    /// 自分の適用でも通知は飛ぶため、区別しないと自分の適用に反応して
    /// 適用し直す無限ループになる。``FrameScheduler/isSettling(_:)`` で
    /// 適用中と直後の猶予を除外する。
    private func handleExternalChange(_ element: AXElement, pid: pid_t) {
        guard let id = idsByElement[element], let record = registry[id],
            !scheduler.isSettling(id)
        else { return }

        // 退避中のウィンドウが動かされた。**放っておくと画面の中に現れる。**
        // 位置しか問題にならないので、読み取らずに退避先へ押し戻す（IPC 1回）。
        if !workspaces.isVisible(record.workspace),
            record.disposition.isTiled || record.disposition.isFloating
        {
            guard allowExternalReaction(id) else { return }
            let origin = stashOrigin()
            let size = stashedFrames[id]?.size ?? record.observedFrame?.size ?? .zero
            log.trace("[\(id)] は退避中なので押し戻す")
            scheduler.reapply(
                id, TargetFrame(rect: CGRect(origin: origin, size: size), setSize: false))
            return
        }

        // 一時的な理由で外しているものは、動いたなら状態が変わったかもしれないので
        // 読み直す。サブディスプレイからメインへ戻った、ネイティブ全画面をやめた、など。
        //
        // **全画面の解除では要素が作り直されないことがある**（Chrome は同じウィンドウの
        // まま戻る。実測）。作り直しの通知を当てにすると、解除しても管理へ戻らず
        // ウィンドウが重なったまま残る。位置か寸法が変わったここで拾う。
        if case .unmanaged(let reason) = record.disposition, reason.isTransient {
            guard allowExternalReaction(id) else { return }
            refreshWindow(element, pid: pid)
            return
        }

        // **フローティングは押し戻さないが、位置は覚え直す。**
        //
        // 覚えないと次の2つが壊れる。
        //   - 枠線が掴む前の位置に取り残される（ドラッグしても付いてこない）
        //   - ワークスペースを往復すると動かす前の位置へ跳ね返る（退避から戻す位置は
        //     `observedFrame` を元にしている）
        if record.disposition.isFloating {
            guard pendingExternalReads.insert(id).inserted else { return }
            applierPool.queue(for: pid).async {
                let observed = AXBridge.readFrame(element.raw)
                Task { @MainActor in
                    self.pendingExternalReads.remove(id)
                    guard let observed else { return }
                    self.registry.update(id) { $0.observedFrame = observed }
                    if self.stashedFrames[id] != nil { self.stashedFrames[id] = observed }
                    guard self.focusedWindowID == id else { return }
                    self.notifyFocusedFrame(measured: (id: id, frame: observed))
                }
            }
            return
        }

        guard desiredFrames[id] != nil, record.disposition.isTiled else { return }

        // 頻度制限はアプリとの押し合いを止めるためのもの。ドラッグ中に効かせると
        // 上限に達した時点で追従が止まり、カクついて見える。
        guard isUserDragging() || allowExternalReaction(id) else { return }

        // 素早いドラッグでは通知が連続して届く。読み取りが飛んでいる間に
        // さらに読み取りを積むと往復が増えるだけなので、1件に絞る。
        guard pendingExternalReads.insert(id).inserted else { return }

        applierPool.queue(for: pid).async {
            let observed = AXBridge.readFrame(element.raw)
            Task { @MainActor in
                self.pendingExternalReads.remove(id)
                guard let observed else { return }
                self.reconcileExternalChange(id, observed: observed)
            }
        }
    }

    /// 読み取りを発行済みのウィンドウ。重複した読み取りを避ける。
    private var pendingExternalReads: Set<CGWindowID> = []

    /// 外部からの変更を「リサイズ」か「移動」かに分けて処理する。
    ///
    /// - **リサイズ**（動いた辺がすべて分割の境界）
    ///   → その分割の比率を更新する。隣が追従し、間隔は設定値どおりに保たれる。
    /// - **移動**（領域の外周など、動かせない辺が動いている）
    ///   → レイアウトが唯一の正なので元へ戻す。
    private func reconcileExternalChange(_ id: CGWindowID, observed: CGRect) {
        // **サブディスプレイへ移されたら手放す。** ここで押し戻すと、利用者が
        // ドラッグしているのに引き戻される綱引きになる。以後は素の macOS と同じ扱い。
        if !managesAllMonitors,
            MonitorManager.isOutsideMain(observed, monitors: monitors.monitors)
        {
            log.info("[\(id)] がメインディスプレイの外へ出たので管理から外す")
            registry.update(id) {
                $0.disposition = .unmanaged(.otherMonitor)
                $0.observedFrame = observed
            }
            desiredFrames.removeValue(forKey: id)
            scheduler.forget(id)
            relayout()
            return
        }

        guard let desired = desiredFrames[id] else { return }

        let tolerance: CGFloat = 2

        // 前回観測した矩形から変わっていないなら、アプリ側の制約で目標とずれたまま
        // 安定している状態。ここで反応すると、そのズレを「利用者のリサイズ」と
        // 誤認して比率を更新し、再配置してまたズレる、という往復が止まらなくなる。
        //
        // 実例: WezTerm は文字セル単位でしかリサイズできないため目標にぴったり
        // 収まらない。これに反応し続けると比率が際限なく動いてレイアウトが壊れる。
        let previous = registry[id]?.observedFrame
        registry.update(id) { $0.observedFrame = observed }
        if let previous, Geometry.isApproximatelyEqual(observed, previous, tolerance: tolerance) {
            return
        }

        let edges = changedEdges(desired: desired, observed: observed, tolerance: tolerance)
        guard !edges.isEmpty else { return }

        // アプリが自分の都合で寸法を変えた場合（文字セル単位への丸め、最小サイズなど）を
        // 「利用者のリサイズ」と解釈すると、比率を更新 → 再配置 → またずれる、の
        // 往復が止まらなくなる。ドラッグ中かどうかで両者を分ける。
        guard isUserDragging() else {
            log.debug("[\(id)] がアプリ都合で変化した。レイアウトへ戻す")
            scheduler.reapply(id, TargetFrame(rect: desired))
            return
        }

        // 動いた辺のすべてが分割の境界に対応するなら「境界を動かした」＝リサイズ。
        // ひとつでも対応しない辺があれば、動かせない外周が動いている＝移動。
        guard let workspace = registry[id]?.workspace,
            let layout = lastLayouts[workspace],
            let node = workspaces[workspace]?.root.findWindow(id)
        else {
            scheduler.reapply(id, TargetFrame(rect: desired))
            return
        }
        let matches = edges.map {
            layout.match(
                edge: $0.oldValue, of: node, orientation: $0.orientation, tolerance: tolerance)
        }
        guard !matches.contains(where: { $0 == nil }) else {
            log.debug("[\(id)] が外部から動かされた。レイアウトへ戻す")
            scheduler.reapply(id, TargetFrame(rect: desired))
            return
        }

        // どの境界かを見分けるのは古いレイアウトで構わないが、**移動量を求める基準は
        // 引き直す**。ドラッグ中は同じ辺について通知が何度も届き、再配置は非同期なので、
        // 適用前の座標を基準にすると同じ量を繰り返し足して追従が暴走する。
        let fresh = currentLayout()
        var moved = false
        for (match, edge) in zip(matches, edges) {
            guard let match else { continue }
            let target = match.boundaryPosition(forEdge: edge.newValue)
            let boundary = fresh?.boundary(like: match.boundary) ?? match.boundary
            if TreeOperations.moveBoundary(boundary, to: target) {
                moved = true
            }
        }
        // 下限に当たって動かせなかったなら、再配置しても何も変わらない。
        guard moved else { return }

        // ドラッグ中の当人には手を出さない。利用者が動かしている最中に
        // こちらからも位置を設定すると引っ張り合いになり、カクついて見える。
        // 追従させるのは隣だけにして、離した後に一度だけ全体を整える。
        draggingWindow = (id: id, at: Date())
        log.trace("[\(id)] のリサイズを分割の比率へ反映")
        relayout()
        scheduleDragSettle()
    }

    /// ドラッグが終わった頃に一度だけ全体を整える。
    ///
    /// ドラッグ中は当人を対象外にしているので、離した時点で本人が
    /// レイアウトに吸い付くようにする。
    private func scheduleDragSettle() {
        guard !isDragSettleScheduled else { return }
        isDragSettleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragGrace + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDragSettleScheduled = false
                guard self.currentDraggingWindow() == nil else {
                    // まだドラッグ中。もう一度待つ。
                    self.scheduleDragSettle()
                    return
                }
                self.draggingWindow = nil
                self.relayout()
            }
        }
    }

    /// ドラッグ中とみなすウィンドウ。猶予を過ぎたら nil。
    private func currentDraggingWindow() -> CGWindowID? {
        guard let dragging = draggingWindow else { return nil }
        guard Date().timeIntervalSince(dragging.at) < Self.dragGrace else { return nil }
        return dragging.id
    }

    // MARK: - レイアウトの見張り

    /// 目標と実際がずれていないかを定期的に確かめ、ずれていたら戻す。
    ///
    /// **通知だけでは足りない。** ドラッグの最後にこちらが戻しても、離した拍子に
    /// 掴んだ先へ書き直されることがある（実測: 戻した直後の読み戻しでは目標に
    /// 一致していたのに、数百 ms 後には掴んだ先に居た）。その後は通知が来ないので、
    /// 通知に頼るだけだと崩れたまま残る。**利用者から見れば「戻ってこない」。**
    ///
    /// `CGWindowList` なら全ウィンドウの矩形が1回 約0.3ms で取れる。AX の往復は
    /// 要らないので、ハングしたアプリが混ざっていても止まらない。
    private func startLayoutGuard() {
        guard layoutGuardTimer == nil, !isDryRun else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.layoutGuardInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.guardTick() }
        }
        timer.tolerance = Self.layoutGuardInterval / 2
        layoutGuardTimer = timer
    }

    /// 見張りの1周期。**画面の一覧は1回だけ読み、両方の用途で使い回す。**
    private func guardTick() {
        let screen = ScreenWindows.snapshot()
        guardTicks += 1

        // **Mission Control の間は何もしない。**
        //
        // 覆いが出ている間、ウィンドウは一覧から消えず**縮小されて並べ替えられる**
        //（実測: (962,28) 955x959 → (968,86) 893x896）。これを「外部から動かされた」と
        // 読むと配置を戻しに行き、実測で2秒に 24 回の AX 書き込みが飛んだ。さらに
        // 「戻しても直らない相手」と判断されて**閉じたあと 20 秒間 見張りが止まる**。
        if let screen, isSystemOverlayVisible(screen: screen) {
            if !wasSystemOverlayVisible {
                wasSystemOverlayVisible = true
                log.debug("画面を覆うものが出ているので見張りを止める（Mission Control など）")
            }
            return
        }
        if wasSystemOverlayVisible {
            wasSystemOverlayVisible = false
            log.debug("画面を覆うものが消えたので見張りを戻す")
        }

        // 取りこぼしの拾い直しは毎周期やる必要がない。走査は AX の往復を伴うので、
        // 見張りより十分に長い間隔にする。
        if guardTicks % Self.reconcileEveryTicks == 0, let screen {
            adoptMissingWindows(screen: screen)
        }
        enforceLayout(screen: screen)
    }

    /// Mission Control などが画面を覆っているか。
    ///
    /// Dock のウィンドウは **PID で選ぶ**。名前（`kCGWindowName`）の取得には
    /// 画面収録の権限が要り、comet はそれを要求しない方針。
    private func isSystemOverlayVisible(screen: [CGWindowID: ScreenWindows.Entry]) -> Bool {
        guard let dock = dockPID ?? SystemOverlay.dockPID() else { return false }
        dockPID = dock
        let sizes = screen.values.filter { $0.ownerPID == dock }.map(\.bounds.size)
        return SystemOverlay.isVisible(
            dockWindowSizes: sizes, displaySizes: monitors.monitors.map(\.frame.size))
    }

    private var dockPID: pid_t?
    private var wasSystemOverlayVisible = false

    private var guardTicks = 0
    /// 取りこぼしの拾い直しを行う周期（見張り何回ぶんか）。0.5秒 × 20 = 10秒。
    private static let reconcileEveryTicks = 20

    /// 台帳に無いウィンドウを見つけて走査し直す。
    ///
    /// **AX の生成通知に取りこぼしがあるので保険が要る。** 生まれた直後の AX 要素は
    /// ウィンドウ ID も属性も返さないことがあり（ブラウザや Electron 製アプリで起きる）、
    /// そこで諦めるとそのウィンドウには個別通知も張られないため**以後どの経路からも
    /// 拾えなくなる**。`CGWindowList` は全ウィンドウを 0.3ms で返すので、
    /// 「監視しているアプリなのに台帳に無い」窓を定期的に探す。
    ///
    /// 何度走査しても拾えない窓（ID を取れない疑似ウィンドウなど）と延々と
    /// 付き合わないよう、同じ ID について試す回数に上限を置く。
    private func adoptMissingWindows(screen: [CGWindowID: ScreenWindows.Entry]) {
        let owners = missingWindows.owners(
            screen: screen,
            known: { self.registry[$0] != nil },
            monitored: { self.observerHub.application(for: $0) != nil },
            own: getpid())
        for pid in owners {
            log.debug("台帳に無いウィンドウがあるので走査し直す pid=\(pid)")
            rescan(pid: pid)
        }
    }

    private var missingWindows = MissingWindowFinder()

    private func enforceLayout(screen: [CGWindowID: ScreenWindows.Entry]?) {
        guard !desiredFrames.isEmpty else { return }
        // **操作中は手を出さない。** 掴んでいる間に押し返すと引っ張り合いになる。
        // 離した直後（dragGrace の間）も待つ。戻すのはそのあと一度で足りる。
        guard currentDraggingWindow() == nil, !isUserDragging() else { return }
        guard let screen else { return }

        let now = ProcessInfo.processInfo.systemUptime
        for (id, desired) in desiredFrames {
            guard let record = registry[id], record.disposition.isTiled,
                workspaces.isVisible(record.workspace),
                let actual = screen[id]?.bounds
            else { continue }
            // 自分の適用による動きの最中は見ない。補正は scheduler の担当。
            guard !scheduler.isSettling(id) else { continue }
            guard LayoutGuard.isOff(actual, from: desired) else {
                layoutGuard.settled(id)
                continue
            }
            // **寄せ切れないと分かっている組み合わせなら、それが落ち着いた姿。**
            // ここで戻しに行くと、補正3回 → 諦め → 20秒後にまた、が永久に続く。
            if LayoutGuard.isSettledAtLimit(
                actual: actual, desired: desired, tolerated: toleratedFrames[id])
            {
                layoutGuard.settled(id)
                continue
            }
            switch layoutGuard.decide(id, now: now) {
            case .restore:
                log.debug(
                    "[\(id)] が目標からずれている。戻す"
                        + "（目標 \(Geometry.rendered(desired)) / 実際 \(Geometry.rendered(actual))）")
                // 実測を控えてから戻す。控えないと、次の適用で「動いていない」と
                // 誤判定して補正が効かなくなる。
                registry.update(id) { $0.observedFrame = actual }
                scheduler.reapply(id, TargetFrame(rect: desired))
            case .giveUp:
                log.warn(
                    "[\(id)] を戻しても目標に落ち着かないので \(Int(LayoutGuard.backoff)) 秒ほど様子を見る"
                        + "（目標 \(Geometry.rendered(desired)) / 実際 \(Geometry.rendered(actual))）")
            case .wait:
                break
            }
        }
    }

    /// 見張りの間隔。
    ///
    /// 1回 約0.3ms なので、この間隔でも常駐コストはほぼ増えない。
    /// 短くするほど戻りが速く見えるが、アプリ側の遅い追従と押し合いやすくなる。
    private static let layoutGuardInterval: TimeInterval = 0.5
    private var layoutGuardTimer: Timer?
    private var layoutGuard = LayoutGuard()

    /// 利用者がマウスでドラッグしている最中か。
    ///
    /// ウィンドウの縁をドラッグするリサイズは必ず左ボタンを押した状態で起きる。
    /// アプリが自分で寸法を変える場合はボタンが押されていない。
    /// これが「利用者の操作」と「アプリ都合の変化」を分ける最も確かな手がかり。
    ///
    /// 通知はドラッグ終了の直後に届くこともあるので、離してから少しの間は
    /// ドラッグ中として扱う。
    private func isUserDragging() -> Bool {
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            lastMouseDownAt = Date()
            return true
        }
        guard let last = lastMouseDownAt else { return false }
        return Date().timeIntervalSince(last) < Self.dragGrace
    }

    private static let dragGrace: TimeInterval = 0.5
    private var lastMouseDownAt: Date?
    /// ドラッグ中のウィンドウ。この間は当人への適用を見送る。
    private var draggingWindow: (id: CGWindowID, at: Date)?
    private var isDragSettleScheduled = false

    private struct EdgeChange {
        let orientation: Orientation
        let oldValue: CGFloat
        let newValue: CGFloat
    }

    private func changedEdges(
        desired: CGRect, observed: CGRect, tolerance: CGFloat
    ) -> [EdgeChange] {
        var result: [EdgeChange] = []
        if abs(observed.minX - desired.minX) > tolerance {
            result.append(.init(orientation: .horizontal, oldValue: desired.minX, newValue: observed.minX))
        }
        if abs(observed.maxX - desired.maxX) > tolerance {
            result.append(.init(orientation: .horizontal, oldValue: desired.maxX, newValue: observed.maxX))
        }
        if abs(observed.minY - desired.minY) > tolerance {
            result.append(.init(orientation: .vertical, oldValue: desired.minY, newValue: observed.minY))
        }
        if abs(observed.maxY - desired.maxY) > tolerance {
            result.append(.init(orientation: .vertical, oldValue: desired.maxY, newValue: observed.maxY))
        }
        return result
    }

    /// 外部変更への反応の頻度制限。自分で動き続けるアプリと無限に押し合わないための歯止め。
    private func allowExternalReaction(_ id: CGWindowID) -> Bool {
        let now = Date()
        var record = restoreAttempts[id] ?? (since: now, count: 0)

        if now.timeIntervalSince(record.since) > Self.restoreWindow {
            record = (since: now, count: 0)
        }
        record.count += 1
        restoreAttempts[id] = record

        if record.count > Self.maxRestoresPerWindow {
            if record.count == Self.maxRestoresPerWindow + 1 {
                log.warn(
                    "[\(id)] が \(Int(Self.restoreWindow)) 秒で \(Self.maxRestoresPerWindow) 回以上動かされた。"
                        + "復元を一旦止める（アプリが自分で動かしている可能性）")
            }
            return false
        }
        return true
    }

    private static let restoreWindow: TimeInterval = 2
    private static let maxRestoresPerWindow = 5

    private func releaseWindow(_ element: AXElement) {
        // 破棄された要素には問い合わせられないので、逆引きで ID を得る。
        guard let id = idsByElement.removeValue(forKey: element) else { return }
        elements.removeValue(forKey: id)
        registry.remove(id)
        scheduler.forget(id)
        minimumSizes.removeValue(forKey: id)
        desiredFrames.removeValue(forKey: id)
        stashedFrames.removeValue(forKey: id)
        priorityWindows.remove(id)
        restoreAttempts.removeValue(forKey: id)
        toleratedFrames.removeValue(forKey: id)
        floatingWindows.remove(id)
        layoutGuard.forget(id)
        missingWindows.forget(id)
        observerHub.unobserve(window: element)
        log.debug("削除 [\(id)]")
        relayout()
    }

    // MARK: - レイアウト

    /// 再配置を要求する。状態を変えたら必ず呼ぶ。
    ///
    /// 実際の算出は次のランループまで遅延させ、**1回にまとめる**。
    /// 起動時は各アプリの走査が個別に完了するため、そのたびに配置すると
    /// 1枚→2枚→3枚…と段階的に動いてカスケードが目に見える。
    /// - Parameter immediately: 次のランループを待たずにその場で配置する。
    ///   新規ウィンドウの初回配置（症状A）だけに使う。まとめる利点より
    ///   1ランループ分の遅れを削るほうが効く。
    public func relayout(immediately: Bool = false) {
        // 起動時は各アプリの走査が別々のランループターンで返るため、
        // そのたびに配置すると 1枚→2枚→3枚… と段階的に動いてカスケードが目に見える。
        // 走査が一巡するまで配置を保留し、揃ってから一度だけ行う。
        guard hasFinishedInitialAdoption else { return }

        if immediately {
            performRelayout()
            return
        }
        guard !isRelayoutScheduled else { return }
        isRelayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRelayoutScheduled = false
                self.performRelayout()
            }
        }
    }

    private func performRelayout() {
        guard !monitors.monitors.isEmpty else { return }

        // 設定でワークスペースの数が減ると、行き場を失ったウィンドウが
        // 「表示もされず退避もされない」まま画面に残る。表示中の側で引き取る。
        for id in registry.allIDs {
            guard let record = registry[id], workspaces[record.workspace] == nil else { continue }
            log.warn("[\(id)] の所属ワークスペース \(record.workspace) が無いので \(workspaces.activeID) へ移す")
            registry.update(id) { $0.workspace = workspaces.activeID }
        }

        var targets: [CGWindowID: TargetFrame] = [:]
        var order: [CGWindowID] = []

        // 見えるほうから先に積む。切替では表示側が先に動いたほうが速く見える。
        // **モニタの並び順で回す。** 順序が揺れると適用順が実行ごとに変わる。
        for pair in workspaces.visiblePairs {
            guard let monitor = monitors.monitor(id: pair.monitor) ?? monitors.primary else {
                continue
            }
            syncTree(of: pair.workspace, on: monitor)
            appendVisibleTargets(
                for: pair.workspace, monitor: monitor, into: &targets, order: &order)
        }
        // どのモニタにも映っていないワークスペースのウィンドウは画面の外へ逃がす。
        appendStashTargets(excluding: workspaces.visibleIDs, into: &targets, order: &order)

        guard !isDryRun else {
            logDryRun(targets: targets, order: order)
            return
        }
        // 実運用でも目標を残す。「何を要求したか」が分からないと、ずれの原因が
        // レイアウト計算なのかアプリ側なのか切り分けられない。
        if log.isEnabled(.trace) {
            logTargets(targets: targets, order: order, level: .trace, prefix: "目標")
        }
        // 新規ウィンドウを先頭へ回す。デフォルト位置に出ている時間がそのまま
        // ちらつきとして見えるので、他より先に動かす（症状A）。
        if !priorityWindows.isEmpty {
            let priority = priorityWindows
            order =
                order.filter { priority.contains($0) } + order.filter { !priority.contains($0) }
            // 配置できたものだけ役目を終える。潰れて送れなかったものは次も先頭に回す。
            priorityWindows.subtract(order)
        }
        if !targets.isEmpty {
            scheduler.submit(targets, order: order)
        }

        // 目標を積んだあとにフォーカスを戻す。順序を逆にすると、まだ退避先にいる
        // ウィンドウをアクティブにしてしまう。
        if let id = pendingFocusRestore {
            pendingFocusRestore = nil
            if let target = workspaces[id] {
                restoreFocus(in: target)
            }
        }
        notifyFocusedFrame()
        notifyTiledFrames()
        // ウィンドウの増減で「どの番号に居るか」が変わる。再配置は増減のたびに
        // 通るので、ここで差分だけ伝える。
        notifyVisibleWorkspacesIfChanged()
    }

    /// 台帳とツリーを一致させる。
    ///
    /// 追加も削除もここへ集まるので、どの経路で状態が変わってもツリーだけがずれない。
    private func syncTree(of workspace: Workspace, on monitor: MonitorManager.Monitor) {
        let root = workspace.root

        // 最初の分割方向は領域の縦横比で決める
        // （AeroSpace の default-root-container-orientation = auto 相当）。
        // 空のうちだけ決め直す。ウィンドウが載っている状態で向きを変えると全部動く。
        //
        // 明示指定も併せて捨てる。ルートは `absorb` で子から向きを引き継ぐので、
        // 入れ子で選ばれた向きがルートに残り続けると自動判定が二度と効かなくなる。
        if root.isEmpty {
            root.isOrientationExplicit = false
            root.orientation = defaultOrientation.resolve(for: monitor.visibleFrame.size)
        }

        // 挿入の基準はツリーの中のノードでなければ意味がない。フォーカスが
        // ダイアログなど管理外のウィンドウにあるときは、最後にフォーカスした
        // タイル対象へ落とす（`focusedNode()` がその面倒を見る）。
        // **基準はそのワークスペースの中のウィンドウに限る**（別のモニタの
        // フォーカスを基準にすると、入る場所が読めなくなる）。
        let focusedInThisWorkspace = focusedNode()?.windowID
        let anchor = focusedInThisWorkspace.flatMap { root.findWindow($0) != nil ? $0 : nil }
        let change = TreeSync.reconcile(
            root: root, tiled: registry.tiledIDs(in: workspace.id),
            focused: anchor,
            strategy: insertionStrategy, normalization: normalization,
            split: pendingSplit)
        if !change.inserted.isEmpty {
            // 予約は1枚で使い切る（i3 も split したあと1枚入れば解除される）。
            pendingSplit = nil
        }
        guard !change.isEmpty else { return }
        for id in change.removed {
            // 管理から外れたウィンドウを「外部から動かされた」と誤認して
            // 引き戻さないよう、戻し先を捨てる。
            desiredFrames.removeValue(forKey: id)
        }
        workspace.isLayoutDirty = true
        log.debug(
            "ws\(workspace.id) のツリーを更新: 追加 \(change.inserted) 削除 \(change.removed) → \(root)")
    }

    /// 表示中のワークスペースの目標矩形を積む。
    private func appendVisibleTargets(
        for workspace: Workspace,
        monitor: MonitorManager.Monitor,
        into targets: inout [CGWindowID: TargetFrame],
        order: inout [CGWindowID]
    ) {
        let root = workspace.root
        // 復帰直後で、非表示中に何も起きていなければ位置の設定だけで足りる。
        // サイズを省くと1ウィンドウあたりの IPC が2回から1回に減る（症状C の対策）。
        let isRestoring = restoringWorkspaces.remove(workspace.id) != nil
        let setSize = !isRestoring || workspace.isLayoutDirty
        workspace.isLayoutDirty = false

        // フローティングは配置計算の対象外。退避から戻すときだけ位置を戻す。
        for id in registry.visibleIDs(in: workspace.id) {
            guard registry[id]?.disposition.isFloating == true,
                let frame = stashedFrames.removeValue(forKey: id)
            else { continue }
            targets[id] = TargetFrame(rect: frame, setSize: false)
            order.append(id)
        }

        guard !root.isEmpty else {
            lastLayouts.removeValue(forKey: workspace.id)
            return
        }

        // 全画面の対象が閉じた・別のワークスペースへ移った場合は忘れる。
        // 残しておくと、次に同じ id が振られたウィンドウが勝手に広がる。
        if let full = workspace.fullscreenWindowID,
            registry[full]?.workspace != workspace.id || registry[full]?.disposition.isTiled != true
        {
            workspace.fullscreenWindowID = nil
        }

        let layout = LayoutEngine.compute(
            root: root, area: monitor.visibleFrame, gaps: gaps, scale: monitor.scale,
            minimums: minimumSizes, fullscreen: workspace.fullscreenWindowID)
        lastLayouts[workspace.id] = layout
        reportOverflows(layout.overflows, in: workspace.id)
        guard !layout.order.isEmpty else {
            log.warn(
                "レイアウトを算出できなかった (ウィンドウ \(root.windowIDs.count) 枚, 領域 \(monitor.visibleFrame))")
            return
        }

        // 領域に対してウィンドウが多すぎると末端の矩形が潰れる。
        // 寸法 0 を送りつけてもアプリは最小サイズに戻すだけで、結果は重なりになる。
        // 送らずに現状維持とし、状況をログに残す。
        let minimumSide: CGFloat = 1
        let dragging = currentDraggingWindow()
        var degenerate = 0
        for id in layout.order {
            guard let rect = layout.frames[id] else { continue }
            guard rect.width >= minimumSide, rect.height >= minimumSide else {
                degenerate += 1
                continue
            }
            // 外部から動かされたときの戻し先として覚えておく。
            // **目標が変わったら「限界」の記憶を捨てる。** 前の目標に届かなかった
            // ことは、新しい目標に届かない理由にはならない。
            if let previous = desiredFrames[id],
                !Geometry.isApproximatelyEqual(previous, rect, tolerance: 0.5)
            {
                toleratedFrames.removeValue(forKey: id)
            }
            desiredFrames[id] = rect
            stashedFrames.removeValue(forKey: id)

            // ドラッグ中の当人には手を出さない。利用者が動かしている最中に
            // こちらからも設定すると引っ張り合いになり、カクついて見える。
            guard id != dragging else { continue }

            // ドラッグ追従中は読み戻しを省いて往復を減らす。素早く動かしても
            // 隣が置いていかれないことを優先し、正確さは仕上げの適用で担保する。
            targets[id] = TargetFrame(rect: rect, setSize: setSize, verify: dragging == nil)
            order.append(id)
        }
        if degenerate > 0 {
            log.warn("領域が足りず \(degenerate) 枚を配置できなかった（ウィンドウ \(layout.order.count) 枚）")
        }
    }

    /// 「最小寸法が収まらない」ことを1度だけ伝える。
    ///
    /// **黙って重ねてはいけない。** アプリは指定より小さくならないので、合計が
    /// 領域を超えると必ず隣にはみ出す。画面上はただ重なって見えるだけなので、
    /// 何が起きているのかと打つ手を出さないと「タイリングが壊れている」と読まれる。
    ///
    /// 同じ状態で言い続けるとログが埋まるので、内容が変わったときだけ出す。
    private func reportOverflows(_ overflows: [LayoutEngine.Overflow], in workspace: WorkspaceID) {
        // **ワークスペースごとに覚える。** 1つしか覚えないと、2画面で表示中の
        // ワークスペースが交互に上書きし合い、同じ警告が再配置のたびに出る。
        guard overflows != reportedOverflows[workspace] else { return }
        reportedOverflows[workspace] = overflows
        for overflow in overflows {
            let axis = overflow.axis == .horizontal ? "幅" : "高さ"
            let names = overflow.windowIDs.compactMap { id -> String? in
                guard let record = registry[id] else { return nil }
                let size = minimumSizes[id]
                let extent =
                    overflow.axis == .horizontal ? size?.width : size?.height
                let name = record.title?.prefix(20) ?? "?"
                return extent.map { "\(name)=\(Int($0))" } ?? String(name)
            }
            log.warn(
                """
                ws\(workspace): \(overflow.windowIDs.count) 枚を並べるには\(axis)が\
                \(Int(overflow.shortfall))pt 足りない\
                （最小寸法の合計 \(Int(overflow.required))pt / 領域 \(Int(overflow.available))pt）。
                アプリは指定より小さくならないので**重なる**。内訳: \(names.joined(separator: ", "))
                1枚をフローティングにする（layout floating tiling）か、
                別のワークスペースへ移す（move-node-to-workspace N）と収まる。
                """)
        }
    }

    /// 直前に伝えた収まらない分割。同じ内容を繰り返し言わないために持つ。
    private var reportedOverflows: [WorkspaceID: [LayoutEngine.Overflow]] = [:]

    /// 表示中でないワークスペースのウィンドウを退避先へ積む。
    ///
    /// **毎回すべて積み直す。** 合成器が「変化なし」を落とすので IPC は増えないうえ、
    /// モニタ構成が変わって退避先が動いたときもこれだけで追従する
    ///（積み直しを怠ると退避中のウィンドウが画面の中に現れる）。
    private func appendStashTargets(
        excluding visible: Set<WorkspaceID>,
        into targets: inout [CGWindowID: TargetFrame],
        order: inout [CGWindowID]
    ) {
        // アプリごと隠せるものは隠す。**隅に 1pt も残らない**のでこちらが本命。
        // 隠せない（表示中のウィンドウも持つ）アプリのぶんだけ隅へ寄せる。
        let plan = hidePlan(visible: visible)
        applyHidePlan(plan)

        let stash = stashOrigin()
        let stashable = Set(plan.stash)
        for workspace in workspaces.all where !visible.contains(workspace.id) {
            for id in registry.visibleIDs(in: workspace.id) where stashable.contains(id) {
                // 初めて退避するときの矩形を覚える。退避すると `observedFrame` は
                // 退避先で上書きされ、元の位置が分からなくなる。
                if stashedFrames[id] == nil {
                    stashedFrames[id] = registry[id]?.observedFrame ?? desiredFrames[id]
                }
                // **戻す位置が分からないウィンドウは退避しない。**
                // 退避してしまうと、次の再配置で退避先そのものを「元の位置」として
                // 覚えてしまい、画面外から永久に戻せなくなる。
                guard let known = stashedFrames[id] else {
                    log.debug("[\(id)] の矩形が分からないので退避を見送る")
                    continue
                }
                // 位置だけを設定する。寸法は触らないので IPC は1回で済む。
                targets[id] = TargetFrame(
                    rect: CGRect(origin: stash, size: known.size), setSize: false)
                order.append(id)
                // 退避中は「レイアウトが定めた位置」を持たない。持たせると
                // 表示中のウィンドウと同じ経路で引き戻そうとしてしまう。
                desiredFrames.removeValue(forKey: id)
            }
        }
    }

    /// 非表示ワークスペースのウィンドウを逃がす座標。
    private func stashOrigin() -> CGPoint {
        Geometry.stashOrigin(outside: monitors.monitors.map(\.frame))
    }

    /// どのアプリを隠し、どのウィンドウを隅へ寄せるかを決める。
    ///
    /// 「今どのアプリが非表示か」は**自分の記録ではなく macOS の実態**を見る。
    /// 利用者が Cmd+Tab で戻したときに追従できるようにするため。
    private func hidePlan(visible: Set<WorkspaceID>) -> HidePlanner.Plan {
        var windows: [HidePlanner.Window] = []
        var hiddenApps: Set<pid_t> = []

        for id in registry.allIDs {
            guard let record = registry[id] else { continue }
            // **サブディスプレイのウィンドウも数に入れる。** 数えないと「全ウィンドウが
            // 隠れているアプリ」と判定され、アプリごと非表示にした拍子に
            // サブディスプレイのウィンドウまで消える。
            // 全モニタを並べる設定ではこの状態にならない（管理下に入る）。
            let onOtherMonitor = record.disposition.isOnOtherMonitor
            guard record.disposition.isTiled || record.disposition.isFloating || onOtherMonitor
            else { continue }
            windows.append(
                HidePlanner.Window(
                    id: id, pid: record.pid, workspace: record.workspace,
                    isAlwaysVisible: onOtherMonitor))
            if NSRunningApplication(processIdentifier: record.pid)?.isHidden == true {
                hiddenApps.insert(record.pid)
            }
        }

        return HidePlanner.plan(
            windows: windows, visibleWorkspaces: visible, hiddenApps: hiddenApps,
            strategy: hiddenWindowStrategy)
    }

    /// アプリの表示・非表示を切り替える。
    ///
    /// `NSRunningApplication` の操作はローカル処理なので AX の往復は要らない。
    /// **隠す前に表示へ戻すほうを先に**行う。順序が逆だと、表示すべきウィンドウが
    /// 一瞬も出ないまま次の非表示に巻き込まれることがある。
    private func applyHidePlan(_ plan: HidePlanner.Plan) {
        // **dry-run では触らない。** アプリを隠すのは「ウィンドウを動かさない」に
        // 反する（画面から消える）。他のウィンドウマネージャが動いている環境で
        // 安全に検証するための逃げ道なので、ここで手を出すと目的を失う。
        //
        // 実機で踏んだ: `--dry-run` でワークスペースを切り替えたら、
        // Parsec・テキストエディット・ターミナルが Cmd+H 相当で消えた。
        guard !isDryRun else {
            if !plan.hide.isEmpty || !plan.unhide.isEmpty {
                log.info(
                    "[dry-run] 非表示にするアプリ \(plan.hide.count) 個 / "
                        + "表示に戻すアプリ \(plan.unhide.count) 個（実際には触らない）")
            }
            return
        }
        for pid in plan.unhide {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            // **通知が届く前に記録を消す。** 消し忘れると、次に利用者が Cmd+H した
            // ときに「comet が隠した」と誤認して列から外さない。
            cometHiddenApps.remove(pid)
            app.unhide()
            log.debug("アプリを表示に戻した pid=\(pid)")
        }
        for pid in plan.hide {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            // **隠す前に記録する。** 逆にすると自分が隠したぶんを利用者の Cmd+H と
            // 誤認して、ワークスペース切替のたびにウィンドウが列から消える。
            cometHiddenApps.insert(pid)
            app.hide()
            log.debug("アプリを非表示にした pid=\(pid)")
        }
    }

    /// 隠したアプリを全て表示へ戻す。**終了前に呼ぶこと。**
    ///
    /// 戻さずに終了すると、利用者からは「アプリが消えた」ようにしか見えない。
    /// - Returns: 戻したアプリの数。
    @discardableResult
    public func unhideAllApplications() -> Int {
        var restored = 0
        for pid in Set(registry.allIDs.compactMap { registry[$0]?.pid }) {
            guard let app = NSRunningApplication(processIdentifier: pid), app.isHidden else {
                continue
            }
            cometHiddenApps.remove(pid)
            app.unhide()
            restored += 1
        }
        return restored
    }

    private func logDryRun(targets: [CGWindowID: TargetFrame], order: [CGWindowID]) {
        log.info("[dry-run] ワークスペース \(workspaces.activeID) / \(order.count) 枚の配置を計算した")
        logTargets(targets: targets, order: order, level: .info, prefix: "[dry-run] ")
    }

    private func logTargets(
        targets: [CGWindowID: TargetFrame], order: [CGWindowID], level: LogLevel, prefix: String
    ) {
        for id in order {
            guard let target = targets[id] else { continue }
            let rect = target.rect
            let title = registry[id]?.title ?? "?"
            let mark = workspaces.isVisible(registry[id]?.workspace ?? -1) ? " " : "退避"
            log.log(
                level,
                "\(prefix) \(mark) [\(id)] \(title.prefix(40)) → "
                    + "(\(Int(rect.minX)), \(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))")
        }
    }

    /// 終了前の後片付け。
    ///
    /// **AX で変えたものは元に戻して終わる。** comet を止めたあとに
    /// 「ウィンドウが画面外に残る」「支援技術向けの挙動が無効なまま」といった
    /// 痕跡を残さないため。
    ///
    /// - Returns: 画面へ戻すウィンドウの枚数。呼び出し側は適用の完了を少し待つ必要がある。
    @discardableResult
    public func prepareForTermination() -> Int {
        let restored = restoreStashedWindows()
        let unhidden = unhideAllApplications()
        if unhidden > 0 {
            log.info("非表示にしていた \(unhidden) 個のアプリを表示に戻した")
        }
        let enhanced = observerHub.restoreEnhancedUserInterfaceForAll()
        if enhanced > 0 {
            log.debug("AXEnhancedUserInterface を \(enhanced) 個のアプリで戻した")
        }
        return restored
    }

    /// 退避中のウィンドウを画面へ戻す。**終了前に呼ぶこと。**
    ///
    /// 戻さずに終了すると、非表示ワークスペースのウィンドウが画面外に残る。
    /// 利用者からは「ウィンドウが消えた」ようにしか見えず、アプリ側の
    /// ウィンドウメニューから呼び戻すしか手が無くなる。
    ///
    /// - Returns: 戻す対象の枚数。呼び出し側は適用の完了を少し待つ必要がある。
    @discardableResult
    public func restoreStashedWindows() -> Int {
        guard !stashedFrames.isEmpty else { return 0 }

        var targets: [CGWindowID: TargetFrame] = [:]
        var order: [CGWindowID] = []
        for (id, frame) in stashedFrames.sorted(by: { $0.key < $1.key }) {
            // 位置だけ戻す。寸法は退避しても変えていない。
            targets[id] = TargetFrame(rect: frame, setSize: false, verify: false)
            order.append(id)
        }
        stashedFrames.removeAll()
        scheduler.submit(targets, order: order)
        return order.count
    }

    // MARK: - WindowResolving

    public func element(for id: CGWindowID) -> AXElement? { elements[id] }
    public func pid(for id: CGWindowID) -> pid_t? { registry[id]?.pid }
    public func observedFrame(for id: CGWindowID) -> CGRect? { registry[id]?.observedFrame }

    public func didApply(_ id: CGWindowID, target: CGRect, observed: CGRect?, succeeded: Bool) {
        if !succeeded {
            log.debug("適用に失敗 [\(id)]")
        }
        let disposition = registry[id]?.disposition
        // 読み戻せた場合はそれを記録する。読めなかった場合（位置のみ設定など）は
        // 楽観的に目標を記録しておく。
        registry.update(id) { $0.observedFrame = observed ?? target }

        guard let observed else { return }
        // 目標に届かなかった場合は枠線を実測値へ合わせ直す。
        if disposition?.showsFocusBorder == true, id == focusedWindowID,
            !Geometry.isApproximatelyEqual(observed, target, tolerance: 1)
        {
            notifyFocusedFrame(measured: (id: id, frame: observed))
        }
        // 最小寸法はタイルの割り当てにだけ使う。状態変更と入れ違いで完了した結果や、
        // フローティングの手動リサイズから学ぶと、タイルへ戻ったときの配置を汚す。
        guard disposition?.isTiled == true else { return }
        learnMinimum(id, target: target, observed: observed)
    }

    /// 補正の上限に達しても追従しなかった。**AX を無視するアプリの自動検出。**
    ///
    /// ずれが小さいものは降格させない。文字セル単位への丸めや最小寸法は
    /// 数十 pt で収まるので、それで常用ウィンドウが浮くと驚く。
    /// 大きくずれているものだけを対象にし、恒久的な対処（`window-rule`）を案内する。
    ///
    /// - Important: **「目標より大きい」を降格の理由にしてはいけない。**
    ///   それはアプリに最小寸法があるという意味で、値は ``learnMinimum(_:target:observed:)``
    ///   が既に覚えている。次の再配置ではその下限を織り込んだ目標になるので、
    ///   放っておけば収まる。
    ///
    ///   実測（Safari）: 幅 476 を要求 → 574 で止まる。同じミリ秒のうちに
    ///   「最小寸法 574 を学習」と「寸法を無視するので降格」が両方走り、
    ///   **学習が降格に打ち消されて Safari のウィンドウが勝手に浮いた。**
    ///
    ///   降格に値するのは次の2つだけ。
    ///   - **位置を無視する** … タイル配置として成立しない
    ///   - **要求より大幅に小さいまま広がらない** … 下限では説明できない
    public func didGiveUp(_ id: CGWindowID, target: CGRect, observed: CGRect) {
        // **ここが押し合いの終点。** 補正で寄せ切れなかった組み合わせを覚えておき、
        // 見張りが同じ目標で同じ実測を見たときは「落ち着いている」と扱う。
        // 覚えないと 20 秒ごとに無駄な往復を繰り返し続ける。
        toleratedFrames[id] = (target: target, actual: observed)

        guard
            FloatingDemotion.shouldDemote(
                target: target, observed: observed, threshold: floatingDemotionThreshold),
            registry[id]?.disposition.isTiled == true
        else {
            return
        }

        // **ネイティブ全画面を「AX を無視するアプリ」と取り違えない。**
        //
        // 全画面へ入ると AX の要素が作り直され、**作られた直後の `AXFullScreen` はまだ
        // `false` を返す**（実測）。その値のままタイル対象として目標を当て続けると当然
        // 追従せず、ここへ落ちてフローティングへ降格してしまう。降格は恒久的なので、
        // 全画面をやめてもそのアプリだけ並ばなくなる（実際に Chrome で起きた）。
        //
        // 形では見分けられない。Chrome の全画面ウィンドウは画面全体ではなく
        // 自前のタブ帯を除いた (0,138) 2560x1526 になる（実測）。落ち着いたあとに
        // 属性を読み直せば `true` が返る（実測）ので、降格の前にそれだけ確かめる。
        // ここは補正しても同じ実測が続いたあとの稀な経路なので、1往復増やしてよい。
        guard let element = elements[id], let pid = registry[id]?.pid else {
            demoteToFloating(id, target: target, observed: observed)
            return
        }
        applierPool.queue(for: pid).async {
            let isFullScreen = AXBridge.readWindowAttributes(element.raw)?.isFullScreen ?? false
            Task { @MainActor in
                // 待っている間に状態が変わっていることがある。
                guard self.registry[id]?.disposition.isTiled == true else { return }
                guard isFullScreen else {
                    self.demoteToFloating(id, target: target, observed: observed)
                    return
                }
                self.log.info("[\(id)] はネイティブ全画面だったので管理から外す")
                self.registry.update(id) {
                    $0.disposition = .unmanaged(.fullScreen)
                    $0.observedFrame = observed
                }
                self.desiredFrames.removeValue(forKey: id)
                self.scheduler.forget(id)
                // **全画面中の寸法を「このアプリの下限」として覚えてはいけない。**
                // 覚えると全画面をやめたあとも画面幅を要求し続け、他のウィンドウが
                // 「領域が足りず配置できなかった」となって重なる（実際にそうなった）。
                self.minimumSizes.removeValue(forKey: id)
                self.relayout()
            }
        }
    }

    /// 指定した寸法を無視するアプリをツリーから外す。
    private func demoteToFloating(_ id: CGWindowID, target: CGRect, observed: CGRect) {
        let record = registry[id]
        // 降格は恒久的な判断なので、最小化やワークスペース切替をまたいでも保つ。
        floatingWindows.insert(id)
        registry.update(id) { $0.disposition = .floating }
        desiredFrames.removeValue(forKey: id)
        log.warn(
            """
            [\(id)] \(record?.title?.prefix(40) ?? "?") が指定した寸法を無視するので
            フローティングへ降格した（要求 \(Int(target.width))x\(Int(target.height)) /
            実際 \(Int(observed.width))x\(Int(observed.height))）。
            毎回こうなるなら設定に書いておくと安定する:
              [[window-rule]]
              if-app-id = "\(record?.bundleID ?? "?")"
              run       = "layout floating"
            """)
        relayout()
    }

    /// 目標より大きくなった＝アプリ側の下限に当たった。学習してレイアウトに反映する。
    ///
    /// 下限を無視して割り当て続けると、そのウィンドウが隣にはみ出して重なり、
    /// 間隔が崩れる。兄弟に譲らせることで配置を成立させる。
    ///
    /// 学習値は単調増加で、実際の下限で頭打ちになるので発散しない。
    /// 兄弟同士の下限が同時に満たせない場合は比例配分に落ちるが、
    /// そこでも学習値は増えないので再配置は繰り返されない。
    private func learnMinimum(_ id: CGWindowID, target: CGRect, observed: CGRect) {
        // ネイティブ全画面へ入った直後は AXFullScreen が一時的に false のことがある。
        // その間の実測は画面サイズだが、要求した位置からも外れている。本物の最小寸法は
        // 左上を保ったまま寸法だけが止まるので、位置まで無視された結果は学習しない。
        guard
            let learned = MinimumSizeLearning.updatedSize(
                current: minimumSizes[id] ?? .zero, target: target, observed: observed)
        else { return }
        minimumSizes[id] = learned
        log.debug(
            "[\(id)] の最小寸法を学習: \(Int(learned.width))x\(Int(learned.height))"
                + "（要求 \(Int(target.width))x\(Int(target.height))）")
        relayout()
    }
}
