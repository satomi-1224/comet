import Carbon.HIToolbox
import Foundation
import CometSupport

/// Carbon の `eventHotKeyExistsErr`。Swift 側に公開されていない環境があるため値を持つ。
private let hotKeyExistsStatus: OSStatus = -9878

/// Carbon がホットキー押下を届けるコールバック。
///
/// `@convention(c)` はキャプチャを持てないため、`HotkeyManager` 自身は
/// `userData` 経由で受け渡す。呼び出しは常にメインランループ上で起きる。
private let hotkeyEventCallback: EventHandlerUPP = {
    (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if isPressed {
            manager.dispatch(identifier: hotKeyID.id)
        } else {
            manager.dispatchRelease(identifier: hotKeyID.id)
        }
    }
    return noErr
}

/// グローバルホットキーの登録と配送。
///
/// `CGEventTap` ではなく Carbon の `RegisterEventHotKey` を使う。
/// 全キーイベントを流さないので常駐コストが原理的にほぼゼロで、
/// 入力監視（Input Monitoring）権限も要らない。
@MainActor
public final class HotkeyManager {

    public typealias Handler = @MainActor (Hotkey) -> Void

    /// ホットキーが離されたときに呼ばれる。
    ///
    /// **Carbon の `kEventHotKeyPressed` はキー連射では繰り返し発火しない**（実測で
    /// 15回送って1回）。押しっぱなしでの追従を得るには、離されるまで呼び出し側が
    /// 自分で繰り返すしかない。そのための合図。
    public var onRelease: (@MainActor (Hotkey) -> Void)?

    public enum ManagerError: Error, Equatable, CustomStringConvertible {
        case notStarted
        case eventHandlerInstallFailed(OSStatus)
        case alreadyRegistered(Hotkey)
        case takenByAnotherProcess(Hotkey)
        case registrationFailed(Hotkey, OSStatus)

        public var description: String {
            switch self {
            case .notStarted:
                "start() を呼ぶ前に register() が呼ばれた"
            case .eventHandlerInstallFailed(let status):
                "Carbon イベントハンドラの登録に失敗 (OSStatus \(status))"
            case .alreadyRegistered(let hotkey):
                "\(hotkey) は既に登録済み"
            case .takenByAnotherProcess(let hotkey):
                """
                \(hotkey) は他のプロセスが既に登録している。
                AeroSpace / Hammerspoon / Raycast などが同じキーを掴んでいないか確認する。
                """
            case .registrationFailed(let hotkey, let status):
                "\(hotkey) の登録に失敗 (OSStatus \(status))"
            }
        }
    }

    private struct Entry {
        let hotkey: Hotkey
        let reference: EventHotKeyRef
        let handler: Handler
    }

    /// EventHotKeyID.signature。4文字コード 'CMET'。
    private static let signature = OSType(0x434D_4554)

    private var entries: [UInt32: Entry] = [:]
    private var identifiersByHotkey: [Hotkey: UInt32] = [:]
    private var nextIdentifier: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    /// Carbon に渡した自分自身への参照。``start()`` で +1 し ``stop()`` で -1 する。
    private var retainedSelf: UnsafeMutableRawPointer?

    private let log: Log

    public init(log: Log = .shared) {
        self.log = log
    }

    public var isRunning: Bool { eventHandler != nil }
    public var registeredCount: Int { entries.count }

    /// Carbon イベントハンドラを設置する。``register(_:handler:)`` の前に必ず呼ぶ。
    ///
    /// Carbon には非保持ポインタではなく**保持したポインタ**を渡す。
    /// 非保持だと、マネージャが解放されたあとにホットキーが押された時点で
    /// 解放済みメモリを参照してクラッシュする。``stop()`` を呼ぶまで解放されない。
    public func start() throws {
        guard eventHandler == nil else { return }

        let pointer = Unmanaged.passRetained(self).toOpaque()
        // 押下と**離し**の両方を受ける。離しを取らないと「押しっぱなし」を検出できない。
        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventCallback,
            specs.count,
            &specs,
            pointer,
            &handlerRef
        )
        guard status == noErr, let handlerRef else {
            Unmanaged<HotkeyManager>.fromOpaque(pointer).release()
            throw ManagerError.eventHandlerInstallFailed(status)
        }
        eventHandler = handlerRef
        retainedSelf = pointer
        log.debug("Carbon イベントハンドラを設置した")
    }

    /// 全ホットキーを解除し、イベントハンドラを撤去する。
    ///
    /// - Important: 呼び出し側が強参照を保持したまま呼ぶこと。
    ///   ``start()`` で積んだ参照をここで下ろすため、他に参照が無いと
    ///   この呼び出しの途中で自身が解放されうる。
    public func stop() {
        unregisterAll()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }

        // メンバへのアクセスを全て終えてから解放する。
        let pointer = retainedSelf
        retainedSelf = nil
        if let pointer {
            Unmanaged<HotkeyManager>.fromOpaque(pointer).release()
        }
    }

    @discardableResult
    public func register(_ hotkey: Hotkey, handler: @escaping Handler) throws -> UInt32 {
        // start() を呼ばずに登録すると、RegisterEventHotKey 自体は成功して
        // そのキーをシステム全体から奪う一方、配送先のハンドラが存在しない。
        // 「そのキーだけ何も起きなくなる」という追跡困難な状態になるので拒否する。
        guard eventHandler != nil else {
            throw ManagerError.notStarted
        }

        guard identifiersByHotkey[hotkey] == nil else {
            throw ManagerError.alreadyRegistered(hotkey)
        }

        if KeySpec.isRisky(hotkey) {
            log.warn(
                """
                \(hotkey) は修飾キー（cmd / alt / ctrl）を伴わないため、
                このキーが全アプリで入力できなくなる。意図した設定か確認すること。
                """)
        }

        let identifier = nextIdentifier
        nextIdentifier += 1

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            if status == hotKeyExistsStatus {
                throw ManagerError.takenByAnotherProcess(hotkey)
            }
            throw ManagerError.registrationFailed(hotkey, status)
        }

        entries[identifier] = Entry(hotkey: hotkey, reference: reference, handler: handler)
        identifiersByHotkey[hotkey] = identifier
        return identifier
    }

    public func unregisterAll() {
        guard !entries.isEmpty else { return }
        for entry in entries.values {
            UnregisterEventHotKey(entry.reference)
        }
        let count = entries.count
        entries.removeAll()
        identifiersByHotkey.removeAll()
        log.debug("ホットキー \(count) 件を解除した")
    }

    /// Carbon コールバックから呼ばれる。
    fileprivate func dispatch(identifier: UInt32) {
        guard let entry = entries[identifier] else {
            log.warn("未知のホットキー ID \(identifier) を受信した")
            return
        }
        log.trace("ホットキー発火: \(entry.hotkey)")
        entry.handler(entry.hotkey)
    }

    /// Carbon コールバックから呼ばれる（離し）。
    fileprivate func dispatchRelease(identifier: UInt32) {
        guard let entry = entries[identifier] else { return }
        log.trace("ホットキー解放: \(entry.hotkey)")
        onRelease?(entry.hotkey)
    }
}
