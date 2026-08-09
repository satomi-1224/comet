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

    /// 分割ごとの比率。利用者がウィンドウの縁をドラッグすると、その分割の比率が変わる。
    private var splitRatios: [CGFloat] = []
    /// 直近の配置で得た分割の記録。動いた辺がどの分割にあたるかの照合に使う。
    private var lastSplits: [SimpleLayout.SplitRecord] = []

    public var gaps: Gaps
    /// レイアウトを計算するがウィンドウは動かさない。
    /// 他の WM が動いている環境でも安全に検証できるようにするための逃げ道。
    public let isDryRun: Bool

    public init(gaps: Gaps = Gaps(inner: 5, outer: 5), dryRun: Bool = false, log: Log = .shared) {
        self.gaps = gaps
        self.isDryRun = dryRun
        self.log = log
        let pool = ApplierPool()
        self.applierPool = pool
        self.observerHub = AXObserverHub(applierPool: pool, log: log)
        self.monitors = MonitorManager(log: log)
        self.scheduler = FrameScheduler(applierPool: pool, log: log)
    }

    public var managedWindowCount: Int { registry.count }
    public var tiledWindowCount: Int { registry.tiledIDs.count }

    // MARK: - 起動

    public func start() {
        scheduler.setResolver(self)

        monitors.onChange = { [weak self] in
            self?.log.info("ディスプレイ構成が変わった")
            self?.relayout()
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
                    self.log.debug(
                        "走査 pid=\(pid) \(info.name ?? "?"): 要素 \(scan.elementCount) 枚, "
                            + "ID取得失敗 \(scan.missingIdentifier), 属性取得失敗 \(scan.missingAttributes)")
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
        relayout()
    }

    private var hasFinishedInitialAdoption = false

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
            restoreAttempts.removeValue(forKey: id)
        }
        observerHub.detach(pid: pid)
        applierPool.removeQueue(for: pid)

        log.debug("アプリを解放: pid=\(pid) (ウィンドウ \(removed.count) 枚)")
        relayout()
    }

    // MARK: - ウィンドウの登録

    private func register(_ windows: [DiscoveredWindow], pid: pid_t, bundleID: String?) {
        guard !windows.isEmpty else { return }

        for window in windows {
            let disposition = WindowClassifier.classify(
                WindowSnapshot(
                    role: window.attributes.role,
                    subrole: window.attributes.subrole,
                    isFullScreen: window.attributes.isFullScreen,
                    isMinimized: window.attributes.isMinimized,
                    size: window.attributes.size ?? .zero))

            elements[window.id] = window.element
            idsByElement[window.element] = window.id
            registry.insert(
                WindowRecord(
                    id: window.id,
                    pid: pid,
                    disposition: disposition,
                    title: window.attributes.title,
                    bundleID: bundleID,
                    observedFrame: window.attributes.frame))

            observerHub.observe(window: window.element, pid: pid)

            switch disposition {
            case .tiled:
                log.debug("追加 [\(window.id)] \(window.attributes.title?.prefix(50) ?? "?")")
            case .unmanaged(let reason):
                log.trace("除外 [\(window.id)] \(window.attributes.title?.prefix(50) ?? "?"): \(reason)")
            }
        }
        relayout()
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

        case .focusedWindowChanged, .applicationActivated:
            // Phase 2 以降で使う。
            break
        }
    }

    private func adoptWindow(_ element: AXElement, pid: pid_t) {
        applierPool.queue(for: pid).async {
            guard let id = AXPrivate.windowID(of: element.raw),
                let attributes = AXBridge.readWindowAttributes(element.raw)
            else { return }
            let discovered = DiscoveredWindow(id: id, element: element, attributes: attributes)
            Task { @MainActor in
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                self.register([discovered], pid: pid, bundleID: bundleID)
            }
        }
    }

    private func refreshWindow(_ element: AXElement, pid: pid_t) {
        applierPool.queue(for: pid).async {
            guard let id = AXPrivate.windowID(of: element.raw),
                let attributes = AXBridge.readWindowAttributes(element.raw)
            else { return }
            Task { @MainActor in
                guard self.registry[id] != nil else { return }
                let disposition = WindowClassifier.classify(
                    WindowSnapshot(
                        role: attributes.role,
                        subrole: attributes.subrole,
                        isFullScreen: attributes.isFullScreen,
                        isMinimized: attributes.isMinimized,
                        size: attributes.size ?? .zero))
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
        guard let id = idsByElement[element],
            desiredFrames[id] != nil,
            registry[id]?.disposition.isTiled == true,
            !scheduler.isSettling(id),
            allowExternalReaction(id)
        else { return }

        applierPool.queue(for: pid).async {
            guard let observed = AXBridge.readFrame(element.raw) else { return }
            Task { @MainActor in
                self.reconcileExternalChange(id, observed: observed)
            }
        }
    }

    /// 外部からの変更を「リサイズ」か「移動」かに分けて処理する。
    ///
    /// - **リサイズ**（動いた辺がすべて分割の境界）
    ///   → その分割の比率を更新する。隣が追従し、間隔は設定値どおりに保たれる。
    /// - **移動**（領域の外周など、動かせない辺が動いている）
    ///   → レイアウトが唯一の正なので元へ戻す。
    private func reconcileExternalChange(_ id: CGWindowID, observed: CGRect) {
        guard let desired = desiredFrames[id] else { return }

        let tolerance: CGFloat = 2
        let edges = changedEdges(desired: desired, observed: observed, tolerance: tolerance)
        guard !edges.isEmpty else { return }

        let matches = edges.map { matchSplit($0, tolerance: tolerance) }

        guard !matches.contains(where: { $0 == nil }) else {
            log.debug("[\(id)] が外部から動かされた。レイアウトへ戻す")
            scheduler.reapply(id, TargetFrame(rect: desired))
            return
        }

        for match in matches.compactMap({ $0 }) {
            guard let ratio = lastSplits[match.index].ratio(forBoundary: match.boundary) else {
                continue
            }
            setSplitRatio(match.index, min(max(ratio, 0.05), 0.95))
        }
        log.debug("[\(id)] のリサイズを分割の比率へ反映した")
        relayout()
    }

    private struct EdgeChange {
        let orientation: SimpleLayout.Orientation
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

    /// 動いた辺がどの分割の境界にあたるかを探す。
    ///
    /// 手前側のウィンドウなら終端が境界そのもの、奥側のウィンドウなら
    /// 始端が「境界 + 間隔」になる。
    private func matchSplit(
        _ edge: EdgeChange, tolerance: CGFloat
    ) -> (index: Int, boundary: CGFloat)? {
        for (index, split) in lastSplits.enumerated() where split.orientation == edge.orientation {
            if abs(split.boundary - edge.oldValue) <= tolerance {
                return (index, edge.newValue)
            }
            if abs(split.boundary + split.gap - edge.oldValue) <= tolerance {
                return (index, edge.newValue - split.gap)
            }
        }
        return nil
    }

    private func setSplitRatio(_ index: Int, _ ratio: CGFloat) {
        while splitRatios.count <= index {
            splitRatios.append(0.5)
        }
        splitRatios[index] = ratio
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
    public func relayout() {
        // 起動時は各アプリの走査が別々のランループターンで返るため、
        // そのたびに配置すると 1枚→2枚→3枚… と段階的に動いてカスケードが目に見える。
        // 走査が一巡するまで配置を保留し、揃ってから一度だけ行う。
        guard hasFinishedInitialAdoption else { return }
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

        let tiled = registry.tiledIDs
        guard !tiled.isEmpty else { return }

        let layout = SimpleLayout.compute(
            count: tiled.count, in: monitor.visibleFrame, gaps: gaps, scale: monitor.scale,
            ratios: splitRatios,
            minimums: tiled.map { minimumSizes[$0] ?? .zero })
        let rects = layout.rects
        lastSplits = layout.splits
        guard rects.count == tiled.count else {
            log.warn("レイアウトを算出できなかった (ウィンドウ \(tiled.count) 枚, 領域 \(monitor.visibleFrame))")
            return
        }

        // 領域に対してウィンドウが多すぎると末端の矩形が潰れる。
        // 寸法 0 を送りつけてもアプリは最小サイズに戻すだけで、結果は重なりになる。
        // 送らずに現状維持とし、状況をログに残す。
        let minimumSide: CGFloat = 1
        var targets: [CGWindowID: TargetFrame] = [:]
        var order: [CGWindowID] = []
        var degenerate = 0
        for (id, rect) in zip(tiled, rects) {
            guard rect.width >= minimumSide, rect.height >= minimumSide else {
                degenerate += 1
                continue
            }
            targets[id] = TargetFrame(rect: rect)
            order.append(id)
            // 外部から動かされたときの戻し先として覚えておく。
            desiredFrames[id] = rect
        }
        if degenerate > 0 {
            log.warn("領域が足りず \(degenerate) 枚を配置できなかった（ウィンドウ \(tiled.count) 枚）")
        }

        guard !isDryRun else {
            log.info("[dry-run] \(order.count) 枚の配置を計算した")
            for id in order {
                guard let rect = targets[id]?.rect else { continue }
                let title = registry[id]?.title ?? "?"
                log.info(
                    "[dry-run]   [\(id)] \(title.prefix(40)) → "
                        + "(\(Int(rect.minX)), \(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))")
            }
            return
        }

        scheduler.submit(targets, order: order)
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
        learnMinimum(id, target: target, observed: observed)
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
