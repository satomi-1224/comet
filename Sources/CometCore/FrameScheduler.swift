import CoreGraphics
import Darwin
import Dispatch
import Foundation
import CometAccessibility
import CometSupport

/// ウィンドウ ID から AX 要素と所属プロセスを引くための口。``Engine`` が実装する。
@MainActor
public protocol WindowResolving: AnyObject {
    func element(for id: CGWindowID) -> AXElement?
    func pid(for id: CGWindowID) -> pid_t?
    func observedFrame(for id: CGWindowID) -> CGRect?
    func didApply(_ id: CGWindowID, target: CGRect, observed: CGRect?, succeeded: Bool)
    /// 補正しても目標へ追従しないことが確定した。
    ///
    /// 「AX でのリサイズを無視するアプリ」を検出できる唯一の合図。
    func didGiveUp(_ id: CGWindowID, target: CGRect, observed: CGRect)
}

extension WindowResolving {
    /// 既定では何もしない。降格の判断は `Engine` の仕事。
    public func didGiveUp(_ id: CGWindowID, target: CGRect, observed: CGRect) {}
}

/// ``FrameCoalescer`` を時間軸に載せ、PID ごとのキューへ振り分ける薄いラッパ。
///
/// 判断そのものは合成器が持つ純粋なロジックで、ここは配送だけを担う。
///
/// タイマーは `DispatchSourceTimer` ではなく自己再スケジュールする `asyncAfter` で回す。
/// suspend/resume の balance を誤ると即クラッシュする一方、こちらは
/// 「待機中なら再スケジュールしない」だけで安全に止まる。
@MainActor
public final class FrameScheduler {

    private var coalescer: FrameCoalescer
    private let applierPool: ApplierPool
    private weak var resolver: (any WindowResolving)?
    private let interval: TimeInterval
    private let tolerance: CGFloat
    private let maxCorrections: Int
    /// 適用のレイテンシ。無効なら何も測らない。
    public let timing: TimingRecorder

    /// 目標を受け取るが **AX には一切書き込まない。**
    ///
    /// 呼び出し側で「投入しない」ようにすると経路が増えたときに必ず漏れる
    ///（実際に外部変更の戻し経路から漏れていた）。**関門はここ一箇所に置く。**
    public var isDryRun = false
    private let log: Log

    private var isTicking = false
    /// 目標どおりにならなかったウィンドウの補正状態。目標が変われば数え直す。
    private var corrections = FrameCorrectionTracker()
    /// 最後に適用を終えた時刻。自分の適用による通知を外部からの変更と誤認しないために使う。
    private var settledAt: [CGWindowID: Date] = [:]

    public init(
        applierPool: ApplierPool,
        interval: TimeInterval = 0.008,
        tolerance: CGFloat = 0.5,
        maxCorrections: Int = 3,
        timing: TimingRecorder = TimingRecorder(isEnabled: false),
        log: Log = .shared
    ) {
        self.timing = timing
        self.applierPool = applierPool
        self.interval = interval
        self.tolerance = tolerance
        self.maxCorrections = maxCorrections
        self.coalescer = FrameCoalescer(tolerance: tolerance)
        self.log = log
    }

    public func setResolver(_ resolver: any WindowResolving) {
        self.resolver = resolver
    }

    public var isIdle: Bool { coalescer.isIdle }

    public func appliedFrame(_ id: CGWindowID) -> CGRect? {
        coalescer.appliedFrame(id)
    }

    /// 目標矩形を投入する。ノンブロッキング。
    public func submit(_ targets: [CGWindowID: TargetFrame], order: [CGWindowID]) {
        guard !targets.isEmpty else { return }
        coalescer.submit(targets, order: order)
        kick()
    }

    public func submit(_ id: CGWindowID, _ target: TargetFrame) {
        coalescer.submit(id, target)
        kick()
    }

    public func forget(_ id: CGWindowID) {
        coalescer.forget(id)
        corrections.forget(id)
        settledAt.removeValue(forKey: id)
    }

    // MARK: - 駆動

    private func kick() {
        guard !isTicking else { return }
        isTicking = true
        // 初回は待たずに走らせる。新規ウィンドウの初回配置（症状A）を1ティック分でも遅らせない。
        tick()
    }

    private func tick() {
        for request in coalescer.drain() {
            dispatch(request)
        }

        // 適用中のものが残っていても、その完了は complete() 経由で再駆動される。
        // ここで回し続けると何もしないウェイクアップを繰り返すことになる。
        guard coalescer.pendingCount > 0 else {
            isTicking = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func dispatch(_ request: FrameRequest) {
        guard let resolver,
            let element = resolver.element(for: request.windowID),
            let pid = resolver.pid(for: request.windowID)
        else {
            // ウィンドウが既に消えている。状態を残すと次の同一 ID を誤判定する。
            coalescer.forget(request.windowID)
            return
        }

        let current = resolver.observedFrame(for: request.windowID)
        let id = request.windowID
        let target = request.target

        guard !isDryRun else {
            // 適用したことにして先へ進める。読み戻しも補正も学習もしない。
            coalescer.complete(request)
            return
        }

        let timing = self.timing
        // 発行と完了の時刻を残す。**「どこで時間を使ったか」を後から追えるようにする。**
        // 同じ pid のウィンドウは直列に処理されるので、遅いアプリが混ざると
        // 後続が待たされる。それが見えるのはこの2行だけ。
        log.trace("適用を発行 [\(id)] \(rendered(target.rect))")
        applierPool.queue(for: pid).async {
            let result = AXBridge.applyFrame(
                target.rect, setSize: target.setSize, verify: target.verify,
                current: current, to: element.raw, timing: timing, pid: pid)
            Task { @MainActor in
                self.log.trace("適用が完了 [\(id)]")
                self.finish(request, result: result)
            }
        }
    }

    /// 自分の適用に起因する動きが落ち着くまでの猶予。
    ///
    /// ウィンドウを動かすと AX の移動・リサイズ通知が飛ぶ。これを外部からの変更と
    /// 誤認すると、自分の適用に反応して適用し直す無限ループになる。
    private static let settleWindow: TimeInterval = 0.25

    /// 自分の適用による動きの最中か。
    public func isSettling(_ id: CGWindowID) -> Bool {
        if coalescer.isActive(id) { return true }
        guard let time = settledAt[id] else { return false }
        return Date().timeIntervalSince(time) < Self.settleWindow
    }

    /// 目標を投げ直す。適用履歴を捨てるので、同じ矩形でも再発行される。
    public func reapply(_ id: CGWindowID, _ target: TargetFrame) {
        coalescer.invalidate(id)
        coalescer.submit(id, target)
        kick()
    }

    private func finish(_ request: FrameRequest, result: AXBridge.FrameApplyResult) {
        let id = request.windowID
        let target = request.target

        // `forget` はキューへ渡した AX 呼び出し自体を取り消せない。全画面へ移った、
        // 最小化された、閉じられた、といった理由で忘れた後に完了が返ってきても、
        // その結果を現在の状態へ混ぜない。特に全画面の実測を最小寸法として学習すると、
        // 解除後も画面いっぱいの寸法を要求し続けてタイリングが壊れる。
        switch coalescer.complete(request) {
        case .discarded:
            log.trace("破棄済みの適用完了を無視 [\(id)]")
            if coalescer.pendingCount > 0 { kick() }
            return
        case .superseded:
            // キー連射中に A の適用中へ B が届いた場合、A の補正を投げると B を
            // 上書きしてウィンドウが一度前の位置へ戻る。古い結果は状態にも混ぜず、
            // 待っている最新目標を直ちに発行する。
            corrections.forget(id)
            log.trace("新しい目標があるため古い適用完了を無視 [\(id)]")
            if coalescer.pendingCount > 0 { kick() }
            return
        case .current:
            break
        }
        settledAt[id] = Date()
        resolver?.didApply(
            id, target: target.rect, observed: result.observed, succeeded: result.succeeded)

        correctIfNeeded(id, target: target, observed: result.observed)

        // 適用中に溜まった分があれば拾い直す。
        if coalescer.pendingCount > 0 {
            kick()
        }
    }

    /// 目標どおりにならなかったら投げ直す。
    ///
    /// アプリの最小サイズや画面端の制約で、設定が成功しても実際の矩形は違いうる。
    /// そのままだと隣との間隔が崩れて重なりや隙間になるので、上限つきで補正する。
    private func correctIfNeeded(_ id: CGWindowID, target: TargetFrame, observed: CGRect?) {
        guard let observed else {
            corrections.forget(id)
            return
        }

        switch corrections.evaluate(
            id, target: target.rect, observed: observed, tolerance: tolerance,
            maxCorrections: maxCorrections)
        {
        case .settled:
            return
        case .giveUp(let reason):
            if reason == .unchangedResult {
                log.debug(
                    "[\(id)] が目標に追従しない。要求 \(rendered(target.rect)) / "
                        + "実際 \(rendered(observed))。同じ実測が続いたため残りの補正を省く")
            } else {
                log.warn(
                    "[\(id)] が目標に追従しない。要求 \(rendered(target.rect)) / 実際 \(rendered(observed))。"
                        + "\(maxCorrections) 回の補正で一致しなかったため諦める（アプリ側の制約と思われる）")
            }
            resolver?.didGiveUp(id, target: target.rect, observed: observed)
            return
        case .retry(let count):
            log.debug("[\(id)] 補正 \(count)/\(maxCorrections): 実際 \(rendered(observed))")
        }

        // 適用履歴を捨てないと「同じ矩形なので不要」と判定されて発行されない。
        coalescer.invalidate(id)
        coalescer.submit(id, target)
        kick()
    }

    private func rendered(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))"
    }

    public func forgetCorrections(_ id: CGWindowID) {
        corrections.forget(id)
    }
}
