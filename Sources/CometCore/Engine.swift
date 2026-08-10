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
///   ホットキーも通知処理も描画も止まる（設計書 §4.2）。
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
    /// 外部変更への反応の頻度制限用。
    private var restoreAttempts: [CGWindowID: (since: Date, count: Int)] = [:]

    /// ワークスペースの集合。**タイル配置のルートはワークスペースごとに持つ。**
    ///
    /// **レイアウト（分割構造と各分割の比率）が唯一の正**であり、ウィンドウの矩形は
    /// ここから導出される（設計書 §5.0）。ウィンドウ側の状態は常に上書き対象で、
    /// 追従しなければ補正し、それでも駄目なら制約として学習してレイアウト側が譲る。
    private let workspaces: WorkspaceManager

    /// 表示中のワークスペースのルート。
    private var root: ContainerNode { workspaces.active.root }

    /// 初回配置を待たせないウィンドウ。**症状A（デフォルト位置に一瞬出る）の対策。**
    ///
    /// SIP 有効下では他プロセスのウィンドウの初回描画を止められないので、
    /// 「通知を受けてから適用が終わるまで」を短くするしかない（設計書 §3.2）。
    private var priorityWindows: Set<CGWindowID> = []

    /// 再配置のあとにフォーカスを戻すべきワークスペース。
    ///
    /// 切替では**目標矩形を積んだあと**にフォーカスを動かす必要がある。
    private var pendingFocusRestore: WorkspaceID?

    /// 次の再配置が「ワークスペースへ復帰した直後」か。
    ///
    /// **このときだけサイズの設定を省ける。** 通常の再配置でも省いてしまうと、
    /// 最小寸法の学習やギャップの変更で寸法が変わったときに反映されない。
    private var isRestoringWorkspace = false

    /// 退避させたときの矩形。
    ///
    /// フローティングは配置計算の対象外なので、戻すべき位置をここで覚えておく。
    /// 退避すると `observedFrame` は退避先に上書きされ、元の位置が分からなくなる。
    private var stashedFrames: [CGWindowID: CGRect] = [:]

    /// 直近のレイアウト。動いた辺がどの分割の境界にあたるかの照合と、
    /// `resize` で点数を比率へ直すために使う。
    private var lastLayout: LayoutEngine.Result?

    /// 今フォーカスされているウィンドウ。新規ウィンドウの挿入位置とコマンドの対象になる。
    private var focusedWindowID: CGWindowID?
    /// フォーカスの新しさを比べるための単調増加値。時刻そのものは要らない。
    private var focusCounter: UInt64 = 0

    public var normalization = NormalizationConfig.default
    /// 新しいウィンドウの入り方。既定は Phase 1 で実機検証した dwindle。
    public var insertionStrategy = TreeSync.InsertionStrategy.split
    /// ルートの分割方向の決め方。
    public var defaultOrientation = DefaultOrientation.auto
    /// ウィンドウルール。**初めて見るウィンドウにだけ**当てる。
    public var windowRules: [WindowRule] = []
    /// 非表示ワークスペースのウィンドウがアクティブになったら、そちらへ移るか。
    ///
    /// 画面外退避方式では Cmd+Tab や Dock から非表示のウィンドウを選べてしまい、
    /// 「アプリは前面だがウィンドウが見えない」状態になる（設計書 §12.6）。
    public var focusFollowsActivation = true

    /// フォーカス中のウィンドウの矩形（AX 座標）が決まったときに呼ばれる。
    ///
    /// **AX の適用完了を待たずに呼ぶ。** 枠線を先に着地させると遅延が視覚的に隠れる
    ///（設計書 §8.2）。フォーカス先が無いときは `nil`。
    public var onFocusedFrameChanged: (@MainActor (CGRect?) -> Void)?

    /// 表示するワークスペースが変わったときに呼ばれる。
    ///
    /// **ウィンドウ移動の発行より前に呼ぶ。** 壁紙とインジケータは自プロセス側の
    /// 処理なので即座に終わり、切替が速く見える（症状D）。
    public var onWorkspaceChanged: (@MainActor (WorkspaceID) -> Void)?
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

    /// 適用のレイテンシをアプリ別に整形した行。`[debug] timing = true` のときだけ中身が入る。
    ///
    /// **「どのアプリが足を引っ張っているか」がここで分かる**（設計書 §11.3）。
    public var timingReport: [String] {
        scheduler.timing.report { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }
    public var isTimingEnabled: Bool { scheduler.timing.isEnabled }

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

            let mark = workspace.id == workspaces.activeID ? "*" : ""
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
            parts.append("退避 \(stashedFrames.count) 枚")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - 起動

    public func start() {
        scheduler.setResolver(self)

        monitors.onChange = { [weak self] in
            guard let self else { return }
            self.log.info("ディスプレイ構成が変わった")
            // 表示中でないワークスペースも寸法が合わなくなる。退避先も動くので、
            // **退避中のウィンドウを新しい退避先へ動かし直さないと画面に現れる**
            //（設計書 §7.6 手順5）。再配置が全ワークスペース分を積み直す。
            self.workspaces.markAllLayoutsDirty()
            self.relayout()
        }
        monitors.start()

        observerHub.onEvent = { [weak self] event in
            self?.handle(event)
        }

        observeApplicationLifecycle()
        adoptRunningApplications()
    }

    public func stop() {
        observerHub.stop()
        registry.removeAll()
        elements.removeAll()
        idsByElement.removeAll()
        for workspace in workspaces.all {
            TreeSync.reconcile(root: workspace.root, tiled: [], normalization: normalization)
        }
        stashedFrames.removeAll()
        lastLayout = nil
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
        }
        observerHub.detach(pid: pid)
        applierPool.removeQueue(for: pid)

        log.debug("アプリを解放: pid=\(pid) (ウィンドウ \(removed.count) 枚)")
        relayout()
    }

    // MARK: - ウィンドウの登録

    /// 判定結果に、フローティング指定を重ねる。
    ///
    /// 判定（``WindowClassifier``）が見ているのは「そもそも管理できるか」で、
    /// フローティングは「管理下に置くが並べない」という選択。混ぜると、
    /// 最小化から戻ったときにフローティング指定が消えてタイルへ戻ってしまう。
    ///
    /// ルールを当てるのは**初めて見るウィンドウのときだけ**。あとから当て直すと
    /// `layout floating tiling` で戻した選択を上書きしてしまう。
    private func resolveDisposition(
        _ classified: WindowDisposition, id: CGWindowID, bundleID: String?, title: String?
    ) -> WindowDisposition {
        guard classified.isTiled else { return classified }

        if let known = registry[id]?.disposition {
            return known.isFloating ? .floating : classified
        }
        let matched = windowRules.first {
            $0.action == .float && $0.matches(bundleID: bundleID, title: title)
        }
        guard matched != nil else { return classified }
        log.debug("[\(id)] \(title?.prefix(40) ?? "?") はルールによりフローティング")
        return .floating
    }

    private func register(
        _ windows: [DiscoveredWindow], pid: pid_t, bundleID: String?, immediately: Bool = false
    ) {
        guard !windows.isEmpty else { return }

        for window in windows {
            let disposition = resolveDisposition(
                WindowClassifier.classify(
                    WindowSnapshot(
                        role: window.attributes.role,
                        subrole: window.attributes.subrole,
                        isFullScreen: window.attributes.isFullScreen,
                        isMinimized: window.attributes.isMinimized,
                        size: window.attributes.size ?? .zero)),
                id: window.id, bundleID: bundleID, title: window.attributes.title)

            elements[window.id] = window.element
            idsByElement[window.element] = window.id
            // 新しいウィンドウは今見えているワークスペースに入る。既知のウィンドウは
            // 所属を保つ（属性の更新で別のワークスペースへ飛ばさない）。
            let workspace = registry[window.id]?.workspace ?? workspaces.activeID
            registry.insert(
                WindowRecord(
                    id: window.id,
                    pid: pid,
                    disposition: disposition,
                    title: window.attributes.title,
                    bundleID: bundleID,
                    observedFrame: window.attributes.frame,
                    workspace: workspace))

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
                self.followActivationIfNeeded(id)
            }
        }
    }

    /// 非表示ワークスペースのウィンドウがアクティブになったら、そちらへ移る。
    ///
    /// 画面外退避方式では Cmd+Tab や Dock から非表示のウィンドウを選べてしまう。
    /// 何もしないと「アプリは前面だがウィンドウが見えない」状態になる（設計書 §12.6）。
    private func followActivationIfNeeded(_ id: CGWindowID) {
        guard focusFollowsActivation,
            let workspace = registry[id]?.workspace,
            workspace != workspaces.activeID,
            workspaces[workspace] != nil
        else { return }

        log.info("[\(id)] がアクティブになったのでワークスペース \(workspace) へ移る")
        switchWorkspace(to: .index(workspace))
    }

    private func noteFocused(_ id: CGWindowID) {
        guard registry[id] != nil else { return }
        focusedWindowID = id
        focusCounter += 1
        root.findWindow(id)?.lastFocusedAt = focusCounter
        notifyFocusedFrame()
    }

    /// 枠線の位置を伝える。
    ///
    /// 目標矩形が分かっていればそれを使う（適用の完了を待たない）。
    /// 分からないもの（フローティングなど）は実測値に合わせる。
    private func notifyFocusedFrame() {
        guard let handler = onFocusedFrameChanged else { return }
        guard let id = focusedWindowOnActiveWorkspace() else {
            handler(nil)
            return
        }
        handler(desiredFrames[id] ?? registry[id]?.observedFrame)
    }

    /// コマンドの対象になるウィンドウノード。
    ///
    /// フォーカスが分からない状況（起動直後など）では、最後にフォーカスされた葉に落とす。
    /// 何も起きないよりは予測できる動きをするほうがよい。
    private func focusedNode() -> WindowNode? {
        if let id = focusedWindowID, let node = root.findWindow(id) { return node }
        return TreeOperations.descendToLeaf(root)
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
            guard let node = focusedNode() else { return }
            guard let target = TreeOperations.focusTarget(from: node, direction: direction) else {
                log.trace("フォーカスの行き先が無い: \(direction.rawValue)")
                return
            }
            focusWindow(target.windowID)

        case .move(let direction):
            guard let node = focusedNode(),
                TreeOperations.move(node, direction: direction)
            else { return }
            relayout()

        case .resize(let dimension, let delta):
            // 点数を比率へ直すには「そのコンテナが配分できる長さ」が要る。
            // `lastLayout` は再配置が非同期なので、直前に木を変えるコマンド
            //（join-with 等）を打たれていると新しいコンテナを知らない。
            // レイアウトは純粋計算なので、ここで作り直すのが確実で安い。
            guard let node = focusedNode(), let layout = currentLayout(),
                TreeOperations.resize(node, dimension: dimension, delta: delta, layout: layout)
            else { return }
            relayout()

        case .joinWith(let direction):
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
        }
    }

    // MARK: - ワークスペース

    /// 表示するワークスペースを切り替える。
    ///
    /// **AX の適用は再配置に任せる。** ここで直接動かすと、
    /// `["move-node-to-workspace 3", "workspace 3"]` のような複数コマンドで
    /// 中間状態が画面に出てしまう。再配置は1回にまとめられるので1フレームで完了する。
    public func switchWorkspace(to target: WorkspaceTarget) {
        let outgoing = workspaces.active

        let switched: Bool
        switch target {
        case .index(let id):
            guard workspaces[id] != nil else {
                log.warn("ワークスペース \(id) は存在しない（1〜\(workspaces.count)）")
                return
            }
            switched = workspaces.activate(id)
        case .backAndForth:
            switched = workspaces.activatePrevious()
            guard switched else {
                log.debug("戻る先のワークスペースがまだ無い")
                return
            }
        }
        guard switched else { return }

        // 離脱側のフォーカスを保存する。戻ってきたときにここへ返す。
        // 他のワークスペースのウィンドウを覚えても意味がないので絞る
        //（focus_follows_activation ではこの状況が普通に起きる）。
        if let focused = focusedWindowID, registry[focused]?.workspace == outgoing.id {
            outgoing.lastFocused = focused
        }
        let incoming = workspaces.active
        isRestoringWorkspace = true

        log.info("ワークスペース \(outgoing.id) → \(incoming.id)")
        // 壁紙とインジケータはウィンドウ移動より先に。どちらも自プロセス側なので
        // 即座に終わり、切替が速く見える（症状D）。
        onWorkspaceChanged?(incoming.id)
        // フォーカスは**再配置のあと**に戻す。先に戻すと、まだ退避先にいる
        // ウィンドウをアクティブにしてしまい「アプリは前面だが見えない」状態になる。
        pendingFocusRestore = incoming.id
        relayout()
    }

    /// フォーカス中のウィンドウを別のワークスペースへ移す。表示は切り替えない。
    public func moveFocusedWindow(to id: WorkspaceID) {
        guard workspaces[id] != nil else {
            log.warn("ワークスペース \(id) は存在しない（1〜\(workspaces.count)）")
            return
        }
        guard let windowID = focusedWindowOnActiveWorkspace(),
            let record = registry[windowID], record.workspace != id
        else { return }

        registry.update(windowID) { $0.workspace = id }
        // 移動元と移動先はどちらも並びが変わる。復帰時にサイズを適用し直す。
        workspaces[record.workspace]?.isLayoutDirty = true
        workspaces[id]?.isLayoutDirty = true

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
    /// どちらも無ければフォーカスは持たない（枠線を消すのは Phase 5）。
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

    /// 今のツリーに対するレイアウト。**副作用は無い**ので必要なときに作り直せる。
    private func currentLayout() -> LayoutEngine.Result? {
        guard let monitor = monitors.primary, !root.isEmpty else { return nil }
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
            registry.update(id) { $0.disposition = .tiled }
            log.info("[\(id)] をタイルに戻した")
            relayout()
            return
        }

        let candidates = arguments.orientations
        guard !candidates.isEmpty else {
            log.warn("layout の引数に向きが無い: \(arguments.map(\.rawValue).joined(separator: " "))")
            return
        }
        guard let node = focusedNode(),
            TreeOperations.cycleOrientation(of: node, among: candidates)
        else { return }
        relayout()
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
            registry.update(id) { $0.disposition = .floating }
            log.info("[\(id)] をフローティングにした")
        case .floating:
            registry.update(id) { $0.disposition = .tiled }
            log.info("[\(id)] をタイルに戻した")
            workspaces.active.isLayoutDirty = true
        case .unmanaged(let reason):
            log.debug("[\(id)] は管理対象外（\(reason)）なので切り替えない")
            return
        }
        relayout()
    }

    private func adoptWindow(_ element: AXElement, pid: pid_t) {
        applierPool.queue(for: pid).async {
            guard let id = AXPrivate.windowID(of: element.raw),
                let attributes = AXBridge.readWindowAttributes(element.raw)
            else { return }
            let discovered = DiscoveredWindow(id: id, element: element, attributes: attributes)
            Task { @MainActor in
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                // 新しいウィンドウの初回配置は待たせない。**症状A の対策。**
                // 適用順の先頭に回し、次のランループを待たずにその場で配置する。
                self.priorityWindows.insert(id)
                self.register([discovered], pid: pid, bundleID: bundleID, immediately: true)
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
                let disposition = self.resolveDisposition(
                    WindowClassifier.classify(
                        WindowSnapshot(
                            role: attributes.role,
                            subrole: attributes.subrole,
                            isFullScreen: attributes.isFullScreen,
                            isMinimized: attributes.isMinimized,
                            size: attributes.size ?? .zero)),
                    id: id, bundleID: record.bundleID, title: attributes.title)
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
        if record.workspace != workspaces.activeID,
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
        guard let layout = lastLayout, let node = root.findWindow(id) else {
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
        guard let monitor = monitors.primary else { return }

        // 設定でワークスペースの数が減ると、行き場を失ったウィンドウが
        // 「表示もされず退避もされない」まま画面に残る。表示中の側で引き取る。
        for id in registry.allIDs {
            guard let record = registry[id], workspaces[record.workspace] == nil else { continue }
            log.warn("[\(id)] の所属ワークスペース \(record.workspace) が無いので \(workspaces.activeID) へ移す")
            registry.update(id) { $0.workspace = workspaces.activeID }
        }

        let workspace = workspaces.active

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

        // 台帳とツリーを一致させる。追加も削除もここへ集まるので、
        // どの経路で状態が変わってもツリーだけがずれることがない。
        //
        // 挿入の基準はツリーの中のノードでなければ意味がない。フォーカスが
        // ダイアログなど管理外のウィンドウにあるときは、最後にフォーカスした
        // タイル対象へ落とす（`focusedNode()` がその面倒を見る）。
        let change = TreeSync.reconcile(
            root: root, tiled: registry.tiledIDs(in: workspace.id),
            focused: focusedNode()?.windowID,
            strategy: insertionStrategy, normalization: normalization)
        if !change.isEmpty {
            for id in change.removed {
                // 管理から外れたウィンドウを「外部から動かされた」と誤認して
                // 引き戻さないよう、戻し先を捨てる。
                desiredFrames.removeValue(forKey: id)
            }
            workspace.isLayoutDirty = true
            log.debug("ツリーを更新: 追加 \(change.inserted) 削除 \(change.removed) → \(treeDescription)")
        }

        var targets: [CGWindowID: TargetFrame] = [:]
        var order: [CGWindowID] = []

        // 見えるほうから先に積む。切替では表示側が先に動いたほうが速く見える。
        appendVisibleTargets(for: workspace, monitor: monitor, into: &targets, order: &order)
        // 表示中でないワークスペースのウィンドウは画面の外へ逃がす。
        appendStashTargets(excluding: workspace.id, into: &targets, order: &order)

        guard !isDryRun else {
            logDryRun(targets: targets, order: order)
            return
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
    }

    /// 表示中のワークスペースの目標矩形を積む。
    private func appendVisibleTargets(
        for workspace: Workspace,
        monitor: MonitorManager.Monitor,
        into targets: inout [CGWindowID: TargetFrame],
        order: inout [CGWindowID]
    ) {
        // 復帰直後で、非アクティブ中に何も起きていなければ位置の設定だけで足りる。
        // サイズを省くと1ウィンドウあたりの IPC が2回から1回に減る（症状C の対策）。
        let isRestoring = isRestoringWorkspace
        isRestoringWorkspace = false
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
            lastLayout = nil
            return
        }

        let layout = LayoutEngine.compute(
            root: root, area: monitor.visibleFrame, gaps: gaps, scale: monitor.scale,
            minimums: minimumSizes)
        lastLayout = layout
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

    /// 表示中でないワークスペースのウィンドウを退避先へ積む。
    ///
    /// **毎回すべて積み直す。** 合成器が「変化なし」を落とすので IPC は増えないうえ、
    /// モニタ構成が変わって退避先が動いたときもこれだけで追従する
    ///（積み直しを怠ると退避中のウィンドウが画面の中に現れる。設計書 §7.6 手順5）。
    private func appendStashTargets(
        excluding activeID: WorkspaceID,
        into targets: inout [CGWindowID: TargetFrame],
        order: inout [CGWindowID]
    ) {
        let stash = stashOrigin()
        for workspace in workspaces.all where workspace.id != activeID {
            for id in registry.visibleIDs(in: workspace.id) {
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

    private func logDryRun(targets: [CGWindowID: TargetFrame], order: [CGWindowID]) {
        log.info("[dry-run] ワークスペース \(workspaces.activeID) / \(order.count) 枚の配置を計算した")
        for id in order {
            guard let target = targets[id] else { continue }
            let rect = target.rect
            let title = registry[id]?.title ?? "?"
            let mark = registry[id]?.workspace == workspaces.activeID ? " " : "退避"
            log.info(
                "[dry-run]  \(mark) [\(id)] \(title.prefix(40)) → "
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
        // 読み戻せた場合はそれを記録する。読めなかった場合（位置のみ設定など）は
        // 楽観的に目標を記録しておく。
        registry.update(id) { $0.observedFrame = observed ?? target }

        guard let observed else { return }
        // 目標に届かなかった場合は枠線を実測値へ合わせ直す（設計書 §8.2）。
        if id == focusedWindowID,
            !Geometry.isApproximatelyEqual(observed, target, tolerance: 1)
        {
            onFocusedFrameChanged?(observed)
        }
        learnMinimum(id, target: target, observed: observed)
    }

    /// 補正の上限に達しても追従しなかった。**AX を無視するアプリの自動検出。**
    ///
    /// ずれが小さいものは降格させない。文字セル単位への丸めや最小寸法は
    /// 数十 pt で収まるので、それで常用ウィンドウが浮くと驚く。
    /// 大きくずれているものだけを対象にし、恒久的な対処（`window-rule`）を案内する。
    public func didGiveUp(_ id: CGWindowID, target: CGRect, observed: CGRect) {
        let gap = max(
            abs(observed.width - target.width), abs(observed.height - target.height))
        guard gap > floatingDemotionThreshold, registry[id]?.disposition.isTiled == true else {
            return
        }

        let record = registry[id]
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
        let slack: CGFloat = 1
        var learned = minimumSizes[id] ?? .zero
        var changed = false

        if observed.width > target.width + slack, observed.width > learned.width {
            learned.width = observed.width
            changed = true
        }
        if observed.height > target.height + slack, observed.height > learned.height {
            learned.height = observed.height
            changed = true
        }

        guard changed else { return }
        minimumSizes[id] = learned
        log.debug(
            "[\(id)] の最小寸法を学習: \(Int(learned.width))x\(Int(learned.height))"
                + "（要求 \(Int(target.width))x\(Int(target.height))）")
        relayout()
    }
}
