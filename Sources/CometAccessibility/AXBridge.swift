import ApplicationServices
import CoreGraphics
import Darwin
import CometSupport

/// Accessibility API の呼び出しを集約する層。
///
/// - Important: **ここの関数は全て PID ごとのキュー上で呼ぶこと。**
///   AX 呼び出しは対象アプリのメインスレッドとの同期 IPC であり、相手がビジーなら
///   呼び出し側スレッドがブロックする。メインスレッドから呼ぶと、他人のアプリの
///   都合で comet 全体が固まる（設計書 §3.1, §4.2）。
public enum AXBridge {

    // MARK: - タイムアウト

    /// メッセージングタイムアウトを設定する。
    ///
    /// 既定は6秒。ハングしたアプリが1つあるだけでそのキューが6秒止まるため、
    /// 短く設定して「そのアプリだけ諦める」ようにする。
    @discardableResult
    public static func setMessagingTimeout(_ seconds: Float, for element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, seconds) == .success
    }

    // MARK: - 読み取り

    /// ウィンドウの属性を**1往復**で読む。
    ///
    /// 属性を個別に読むと1つにつき1往復かかる。`AXUIElementCopyMultipleAttributeValues`
    /// は public API でありながら複数属性をまとめて取得できるので、必ずこちらを使う。
    /// 新規ウィンドウのちらつき（症状A）は、この往復回数がそのまま遅延になる。
    /// 一括で読む属性。並び順が返り値の添字に対応する。
    ///
    /// 要素数はここから導出する。ハードコードすると属性を足したときに
    /// 全ウィンドウが無言で検出不能になる。
    private static let windowAttributeNames = [
        AXAttribute.role,
        AXAttribute.subrole,
        AXAttribute.title,
        AXAttribute.position,
        AXAttribute.size,
        AXAttribute.minimized,
        AXAttribute.fullScreen,
    ]

    public static func readWindowAttributes(_ element: AXUIElement) -> AXWindowAttributes? {
        var raw: CFArray?
        // オプション 0 = 途中でエラーが出ても止めない。
        // 未対応の属性はエラーを包んだ AXValue として同じ位置に入るので、
        // 添字と属性の対応がずれない。
        let error = AXUIElementCopyMultipleAttributeValues(
            element, windowAttributeNames as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &raw)

        guard error == .success, let values = raw as? [Any],
            values.count == windowAttributeNames.count
        else {
            return nil
        }

        return AXWindowAttributes(
            role: values[0] as? String,
            subrole: values[1] as? String,
            title: values[2] as? String,
            position: point(from: values[3]),
            size: size(from: values[4]),
            isMinimized: values[5] as? Bool ?? false,
            isFullScreen: values[6] as? Bool ?? false)
    }

    /// アプリが持つウィンドウ要素の一覧。
    ///
    /// - Returns: 要素の配列と、取得に失敗した場合の `AXError`。
    public static func windowElements(
        of application: AXUIElement
    ) -> (elements: [AXUIElement], error: AXError?) {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application, AXAttribute.windows as CFString, &raw)
        guard error == .success else { return ([], error) }
        guard let array = raw as? [AXUIElement] else { return ([], nil) }
        return (array, nil)
    }

    /// ウィンドウ走査の結果と、脱落の内訳。
    ///
    /// 「ウィンドウが並ばない」ときに、そもそも見えていないのか、
    /// ID や属性の取得に失敗しているのかを切り分けられるようにする。
    public struct WindowScan: Sendable {
        public var windows: [DiscoveredWindow] = []
        public var elementCount: Int = 0
        public var missingIdentifier: Int = 0
        public var missingAttributes: Int = 0
        public var listError: String?
        /// ID を取れなかった理由。件数だけでは疑似ウィンドウなのか権限の問題なのか
        /// 切り分けられないので、理由を種類ごとに残す。
        public var identifierErrors: [String] = []
    }

    /// アプリのウィンドウを走査し、識別子と属性を揃えて返す。
    ///
    /// `CGWindowID` の取得も属性読み取りも IPC なので、まとめてキュー上で行う。
    public static func scanWindows(of application: AXUIElement) -> WindowScan {
        var scan = WindowScan()
        let (elements, error) = windowElements(of: application)
        scan.elementCount = elements.count
        scan.listError = error.map { "AXError(\($0.rawValue))" }

        for element in elements {
            let id: CGWindowID
            do {
                id = try AXPrivate.identifier(of: element)
            } catch {
                scan.missingIdentifier += 1
                let reason = "\(error)"
                if !scan.identifierErrors.contains(reason) {
                    scan.identifierErrors.append(reason)
                }
                continue
            }
            guard let attributes = readWindowAttributes(element) else {
                scan.missingAttributes += 1
                continue
            }
            scan.windows.append(
                DiscoveredWindow(id: id, element: AXElement(element), attributes: attributes))
        }
        return scan
    }

    /// アプリが今フォーカスしているウィンドウの ID。
    ///
    /// `AXApplicationActivated` は「どのアプリが前面に来たか」しか伝えないので、
    /// ウィンドウを特定するにはここで1往復して問い合わせる。
    public static func focusedWindowID(of application: AXUIElement) -> CGWindowID? {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, AXAttribute.focusedWindow as CFString, &raw) == .success,
            let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // CF 型への条件付きキャストは中身に関わらず常に成功してしまうため、
        // 確認は `CFGetTypeID` で行うしかない。
        return AXPrivate.windowID(of: value as! AXUIElement)
    }

    /// 支援技術向けの非公開属性 `AXEnhancedUserInterface` の値。
    ///
    /// これが `true` のアプリでは、ウィンドウのリサイズに追加処理やアニメーションが
    /// 挟まり `SetAttributeValue` が顕著に遅くなる（設計書 §3.1 e）。
    /// 皮肉なことに、**支援技術（= WM 自身）が AX 接続した時点で自動的に `true` に
    /// なる**ことがある。
    public static func enhancedUserInterface(of application: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, AXAttribute.enhancedUserInterface as CFString, &raw) == .success
        else { return nil }
        return raw as? Bool
    }

    @discardableResult
    public static func setEnhancedUserInterface(_ enabled: Bool, on application: AXUIElement)
        -> Bool
    {
        AXUIElementSetAttributeValue(
            application, AXAttribute.enhancedUserInterface as CFString,
            (enabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    // MARK: - 書き込み

    /// ウィンドウを前面に出してフォーカスする。
    ///
    /// `AXMain` の設定だけでは前面に来ないことがあり、`AXRaise` だけでは
    /// キー入力の宛先が変わらない。両方を行う。
    ///
    /// - Important: **アプリ自体のアクティブ化はここではできない。**
    ///   `NSRunningApplication.activate()` はメインスレッド専用なので呼び出し側で行う。
    ///   これをしないとキー入力が前のアプリに届き続ける。
    @discardableResult
    public static func focus(_ element: AXUIElement) -> Bool {
        let isMain =
            AXUIElementSetAttributeValue(element, AXAttribute.main as CFString, kCFBooleanTrue)
            == .success
        let raised = AXUIElementPerformAction(element, AXAction.raise as CFString) == .success
        return isMain && raised
    }

    /// ウィンドウを閉じる。
    ///
    /// AX に「閉じる」という操作は無いので、**閉じるボタンを押す**という形で行う。
    /// ボタンを持たないウィンドウ（一部のパネル）では失敗する。
    @discardableResult
    public static func close(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, AXAttribute.closeButton as CFString, &raw)
                == .success,
            let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return false }
        return AXUIElementPerformAction(value as! AXUIElement, AXAction.press as CFString)
            == .success
    }

    /// ウィンドウを目標矩形へ動かす。
    ///
    /// AX には位置とサイズを一括設定する API が無いため最低2回の IPC が要る。
    ///
    /// **順序は必ず「位置 → サイズ」。**
    ///
    /// AX の位置は画面外へも設定できる（ワークスペースの画面外退避が成立するのはこのため）
    /// 一方、**サイズは現在位置から画面端までに頭打ちされる**。したがって古い位置のまま
    /// 先にサイズを設定すると、移動先では収まるはずの幅が切り詰められる。
    ///
    /// Phase 1 の実機検証で確認した例:
    /// x=1707 にあるウィンドウを (5, 61) 1273×1598 へ動かす際、サイズを先に設定すると
    /// 幅が **853 = 2560 − 1707**、つまり画面右端までの残り幅に切り詰められた。
    /// 位置を先に設定すればこの頭打ちは起きない。
    ///
    /// - Parameters:
    ///   - current: 直前に観測した矩形。現状は使わないが、Phase 4 の補正判定で使う。
    ///   - setSize: `false` なら位置だけを設定して IPC を1回に減らす。
    /// - Returns: 設定の成否と、設定直後に読み戻した実際の矩形。
    public static func applyFrame(
        _ target: CGRect,
        setSize: Bool,
        verify: Bool = true,
        current: CGRect?,
        to element: AXUIElement,
        timing: TimingRecorder? = nil,
        pid: pid_t = 0
    ) -> FrameApplyResult {
        // 引数名 setSize が静的メソッド setSize(_:on:) を隠すので Self. で明示する。
        let moved = measured(timing, "setPosition", pid) {
            Self.setPosition(target.origin, on: element)
        }
        guard setSize else {
            return FrameApplyResult(succeeded: moved, observed: nil)
        }
        let sized = measured(timing, "setSize", pid) { Self.setSize(target.size, on: element) }

        // 設定が成功しても、アプリの最小サイズや画面端の制約で実際の矩形は違いうる。
        // 目標どおりに並んでいるかを保証するには読み戻すしかない（1往復）。
        // ドラッグ追従中は往復を削るために省略する。
        let observed =
            verify ? measured(timing, "readFrame", pid) { Self.readFrame(element) } : nil
        return FrameApplyResult(succeeded: moved && sized, observed: observed)
    }

    /// 計測が無効なら余計な処理を挟まずに呼ぶ。
    private static func measured<T>(
        _ timing: TimingRecorder?, _ operation: String, _ pid: pid_t, _ body: () -> T
    ) -> T {
        guard let timing, timing.isEnabled else { return body() }
        return timing.measure(operation, pid: pid, body)
    }

    /// 適用の結果。
    public struct FrameApplyResult: Sendable {
        /// AX の設定呼び出しが成功したか。実際に反映されたかは別。
        public let succeeded: Bool
        /// 設定直後に読み戻した矩形。読めなければ nil。
        public let observed: CGRect?
    }

    /// 位置とサイズを**1往復**で読む。
    public static func readFrame(_ element: AXUIElement) -> CGRect? {
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element, [AXAttribute.position, AXAttribute.size] as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard error == .success, let values = raw as? [Any], values.count == 2,
            let origin = point(from: values[0]), let size = size(from: values[1])
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    public static func setPosition(_ point: CGPoint, on element: AXUIElement) -> Bool {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(
            element, AXAttribute.position as CFString, axValue) == .success
    }

    @discardableResult
    public static func setSize(_ size: CGSize, on element: AXUIElement) -> Bool {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(
            element, AXAttribute.size as CFString, axValue) == .success
    }

    // MARK: - 変換

    private static func point(from value: Any) -> CGPoint? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &result) else { return nil }
        return result
    }

    private static func size(from value: Any) -> CGSize? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &result) else { return nil }
        return result
    }
}
