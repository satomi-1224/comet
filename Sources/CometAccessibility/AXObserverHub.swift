import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import CometSupport

/// `AXObserver` を並行境界を越えて運ぶための箱。
public struct AXObserverBox: @unchecked Sendable {
    public let raw: AXObserver
    public init(_ raw: AXObserver) { self.raw = raw }
}

public enum AXEvent: Sendable {
    case windowCreated(pid: pid_t, element: AXElement)
    case elementDestroyed(pid: pid_t, element: AXElement)
    case focusedWindowChanged(pid: pid_t, element: AXElement)
    case windowMoved(pid: pid_t, element: AXElement)
    case windowResized(pid: pid_t, element: AXElement)
    case windowMiniaturized(pid: pid_t, element: AXElement)
    case windowDeminiaturized(pid: pid_t, element: AXElement)
    case applicationActivated(pid: pid_t)
}

/// AX 通知の受信口。
///
/// 通知はメインランループに届く。受信そのものは軽いので問題ないが、
/// **ハンドラ内で同期 AX 呼び出しをしてはならない**。属性が必要なら PID キューへ回す。
private let axObserverCallback: AXObserverCallback = {
    (_: AXObserver, element: AXUIElement, notification: CFString,
        refcon: UnsafeMutableRawPointer?) in
    guard let refcon else { return }
    let hub = Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    let boxed = AXElement(element)
    MainActor.assumeIsolated {
        hub.handle(notification: name, element: boxed)
    }
}

/// アプリ要素に対して張る通知。ウィンドウ生成やフォーカス変化はここに届く。
///
/// PID キュー上のクロージャから参照するため、`@MainActor` 隔離される型の
/// 静的プロパティではなくファイルスコープに置く。
private let applicationNotifications = [
    AXNotification.windowCreated,
    AXNotification.focusedWindowChanged,
    AXNotification.mainWindowChanged,
    AXNotification.applicationActivated,
    AXNotification.windowMiniaturized,
    AXNotification.windowDeminiaturized,
]

/// 個々のウィンドウ要素に対して張る通知。破棄と実移動はここでしか取れない。
private let windowNotifications = [
    AXNotification.uiElementDestroyed,
    AXNotification.windowMoved,
    AXNotification.windowResized,
]

/// `UnsafeMutableRawPointer` を並行境界を越えて運ぶための箱。
/// コールバックへ渡す refcon は不変なので受け渡しは安全。
private struct SendablePointer: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

/// アプリごとに `AXObserver` を張り、ウィンドウの生成・破棄・移動を受け取る。
///
/// 新規ウィンドウのちらつき（症状A）対策として、**アプリの起動を検知した時点で
/// 監視を張る**。ウィンドウが生まれてから監視を始めたのでは間に合わない。
@MainActor
public final class AXObserverHub {

    public var onEvent: (@MainActor (AXEvent) -> Void)?

    private var observers: [pid_t: AXObserverBox] = [:]
    private var applications: [pid_t: AXElement] = [:]
    private var observedWindows: [AXElement: pid_t] = [:]
    /// `AXEnhancedUserInterface` を自分で無効化したアプリ。detach と stop で戻す。
    private var disabledEnhancedUI: Set<pid_t> = []

    /// ウィンドウ操作を遅くする `AXEnhancedUserInterface` を無効化するか。
    ///
    /// これが `true` のアプリではリサイズに追加処理やアニメーションが挟まる。
    /// 皮肉なことに **WM 自身が AX 接続した時点で立つ**ことがあるので、
    /// 立てたのがこちらなら降ろしてよい（設計書 §3.1 e）。
    ///
    /// - Note: 設計書は「操作の直前に落として直後に戻す」としているが、それだと
    ///   1回の適用につき IPC が2回増える。**管理している間は落としたままにし、
    ///   手放すときに戻す**方式にした。VoiceOver を併用する場合はここを `false` にする。
    public var disablesEnhancedUserInterface = true

    /// コールバックに渡した自分自身への参照。
    private var retainedSelf: UnsafeMutableRawPointer?

    private let applierPool: ApplierPool
    /// AX メッセージングのタイムアウト（秒）。ハングしたアプリを待ち続けないための上限。
    private let messagingTimeout: Float
    private let log: Log

    public init(applierPool: ApplierPool, messagingTimeout: Float = 0.1, log: Log = .shared) {
        self.applierPool = applierPool
        self.messagingTimeout = messagingTimeout
        self.log = log
    }

    public var attachedCount: Int { observers.count }

    // MARK: - アプリ単位

    /// アプリの監視を開始する。
    ///
    /// `AXObserverCreate` とランループへの登録はローカル処理なのでメインで行い、
    /// IPC を伴う `AXObserverAddNotification` は PID キューへ回す。
    @discardableResult
    public func attach(pid: pid_t) -> Bool {
        guard observers[pid] == nil else { return true }

        var raw: AXObserver?
        let status = AXObserverCreate(pid, axObserverCallback, &raw)
        guard status == .success, let observer = raw else {
            log.debug("AXObserver を作れない pid=\(pid) (\(status.rawValue))")
            return false
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode)

        let application = AXElement(AXUIElementCreateApplication(pid))
        observers[pid] = AXObserverBox(observer)
        applications[pid] = application

        let box = AXObserverBox(observer)
        let pointer = SendablePointer(raw: selfPointer())
        let timeout = messagingTimeout
        let disablesEnhanced = disablesEnhancedUserInterface
        applierPool.queue(for: pid).async { [weak self] in
            // AXObserverAddNotification は IPC を伴うので PID キュー上で行う。
            // AXObserverCreate とランループ登録はローカル処理なのでメインで済ませてある。
            AXBridge.setMessagingTimeout(timeout, for: application.raw)
            for name in applicationNotifications {
                AXObserverAddNotification(box.raw, application.raw, name as CFString, pointer.raw)
            }

            guard disablesEnhanced, AXBridge.enhancedUserInterface(of: application.raw) == true
            else { return }
            AXBridge.setEnhancedUserInterface(false, on: application.raw)
            Task { @MainActor in
                self?.noteEnhancedUserInterfaceDisabled(pid: pid)
            }
        }
        return true
    }

    private func noteEnhancedUserInterfaceDisabled(pid: pid_t) {
        guard applications[pid] != nil else {
            // すでに手放している。読んだ時点の値へ戻す責任は残る。
            restoreEnhancedUserInterface(pid: pid, application: AXElement(AXUIElementCreateApplication(pid)))
            return
        }
        disabledEnhancedUI.insert(pid)
        log.debug("AXEnhancedUserInterface を無効化した pid=\(pid)")
    }

    /// 落とした `AXEnhancedUserInterface` を戻す。
    private func restoreEnhancedUserInterface(pid: pid_t, application: AXElement) {
        applierPool.queue(for: pid).async {
            AXBridge.setEnhancedUserInterface(true, on: application.raw)
        }
    }

    public func detach(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        if disabledEnhancedUI.remove(pid) != nil, let application = applications[pid] {
            restoreEnhancedUserInterface(pid: pid, application: application)
        }
        applications.removeValue(forKey: pid)
        observedWindows = observedWindows.filter { $0.value != pid }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer.raw),
            .defaultMode)
    }

    public func application(for pid: pid_t) -> AXElement? {
        applications[pid]
    }

    /// 落とした `AXEnhancedUserInterface` を全て戻す。**終了前に呼ぶこと。**
    ///
    /// 戻さずに終了すると、支援技術向けの挙動が comet を止めたあとも無効なままになる。
    /// - Returns: 戻す対象の数。適用は PID キュー上で非同期に進む。
    @discardableResult
    public func restoreEnhancedUserInterfaceForAll() -> Int {
        let targets = disabledEnhancedUI
        disabledEnhancedUI.removeAll()
        for pid in targets {
            let application = applications[pid] ?? AXElement(AXUIElementCreateApplication(pid))
            restoreEnhancedUserInterface(pid: pid, application: application)
        }
        return targets.count
    }

    // MARK: - ウィンドウ単位

    /// ウィンドウ個別の通知を張る。破棄と実移動はアプリ要素には届かない。
    public func observe(window: AXElement, pid: pid_t) {
        guard let observer = observers[pid], observedWindows[window] == nil else { return }
        observedWindows[window] = pid

        let pointer = SendablePointer(raw: selfPointer())
        applierPool.queue(for: pid).async {
            for name in windowNotifications {
                AXObserverAddNotification(observer.raw, window.raw, name as CFString, pointer.raw)
            }
        }
    }

    public func unobserve(window: AXElement) {
        guard let pid = observedWindows.removeValue(forKey: window),
            let observer = observers[pid]
        else { return }

        applierPool.queue(for: pid).async {
            for name in windowNotifications {
                AXObserverRemoveNotification(observer.raw, window.raw, name as CFString)
            }
        }
    }

    // MARK: - 停止

    public func stop() {
        for pid in observers.keys {
            detach(pid: pid)
        }
        observers.removeAll()
        applications.removeAll()
        observedWindows.removeAll()

        let pointer = retainedSelf
        retainedSelf = nil
        if let pointer {
            Unmanaged<AXObserverHub>.fromOpaque(pointer).release()
        }
    }

    // MARK: - 内部

    /// コールバックへ渡すポインタ。
    ///
    /// 非保持で渡すと、ハブが解放されたあとに通知が届いた時点で解放済みメモリを
    /// 参照する。``stop()`` を呼ぶまで解放されないよう保持する。
    private func selfPointer() -> UnsafeMutableRawPointer {
        if let retainedSelf { return retainedSelf }
        let pointer = Unmanaged.passRetained(self).toOpaque()
        retainedSelf = pointer
        return pointer
    }

    fileprivate func handle(notification: String, element: AXElement) {
        guard let onEvent else { return }
        // 通知に載っている要素はウィンドウのこともアプリのこともある。
        // どちらでも PID は取れる。
        guard let pid = element.pid else { return }

        switch notification {
        case AXNotification.windowCreated:
            onEvent(.windowCreated(pid: pid, element: element))
        case AXNotification.uiElementDestroyed:
            onEvent(.elementDestroyed(pid: pid, element: element))
        case AXNotification.focusedWindowChanged, AXNotification.mainWindowChanged:
            onEvent(.focusedWindowChanged(pid: pid, element: element))
        case AXNotification.windowMoved:
            onEvent(.windowMoved(pid: pid, element: element))
        case AXNotification.windowResized:
            onEvent(.windowResized(pid: pid, element: element))
        case AXNotification.windowMiniaturized:
            onEvent(.windowMiniaturized(pid: pid, element: element))
        case AXNotification.windowDeminiaturized:
            onEvent(.windowDeminiaturized(pid: pid, element: element))
        case AXNotification.applicationActivated:
            onEvent(.applicationActivated(pid: pid))
        default:
            break
        }
    }
}
