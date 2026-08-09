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
    func didApply(_ id: CGWindowID, frame: CGRect, succeeded: Bool)
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
    private let log: Log

    private var isTicking = false

    public init(
        applierPool: ApplierPool,
        interval: TimeInterval = 0.008,
        tolerance: CGFloat = 0.5,
        log: Log = .shared
    ) {
        self.applierPool = applierPool
        self.interval = interval
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

        applierPool.queue(for: pid).async {
            let succeeded = AXBridge.applyFrame(
                target.rect, setSize: target.setSize, current: current, to: element.raw)
            Task { @MainActor in
                self.finish(id, frame: target.rect, succeeded: succeeded)
            }
        }
    }

    private func finish(_ id: CGWindowID, frame: CGRect, succeeded: Bool) {
        coalescer.complete(id)
        resolver?.didApply(id, frame: frame, succeeded: succeeded)
        // 適用中に溜まった分があれば拾い直す。
        if coalescer.pendingCount > 0 {
            kick()
        }
    }
}
