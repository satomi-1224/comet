import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 検証用の合成イベント送出。
///
/// **これは製品機能ではなく検証の足場。** 手で押さないと確かめられなかった項目
/// （キー連射で発火するか、縁のドラッグに追従するか）を機械的に判定するために置く。
///
/// - Important: イベントの送出には**送る側**にアクセシビリティ権限が要る。
///   新しく作った小さなバイナリには権限が無いので、**権限を持っている comet 自身**が
///   送るしかない。そのため製品バイナリにこの口がある。
public enum SyntheticEvents {

    /// Carbon の修飾キービットを CGEvent のフラグへ変換する。
    ///
    /// `Hotkey.modifiers` は Carbon 側のビット（`cmdKey` 等）で、
    /// `CGEventFlags` とは別物なので明示的に写す。
    public static func flags(for modifiers: UInt32) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.maskCommand) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.maskAlternate) }
        if modifiers & UInt32(controlKey) != 0 { result.insert(.maskControl) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.maskShift) }
        return result
    }

    /// ホットキーを押す。
    ///
    /// - Important: **修飾キー自体のイベントも送る必要がある。**
    ///   `CGEvent.flags` を立てるだけでは Carbon のホットキーは発火しない
    ///   （ウィンドウサーバが持つ「今押されている修飾キー」の状態が変わらないため）。
    ///   実測でこれが原因だった。
    ///
    /// - Parameter count: keyDown を送る回数。**キーを押しっぱなしにしたときの
    ///   OS のキー連射は「keyUp を挟まない keyDown の連続」なので、
    ///   これを 2 以上にすると連射を再現できる。**
    /// - Returns: 送出した keyDown の回数。
    @discardableResult
    public static func postKey(
        _ hotkey: Hotkey, count: Int = 1, interval: TimeInterval = 0.05
    ) -> Int {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = flags(for: hotkey.modifiers)
        let keyCode = CGKeyCode(hotkey.keyCode)

        // 押す順は cmd → alt → ctrl → shift。離すのは逆順。
        let modifierKeys: [(CGKeyCode, CGEventFlags)] = [
            (CGKeyCode(kVK_Command), .maskCommand),
            (CGKeyCode(kVK_Option), .maskAlternate),
            (CGKeyCode(kVK_Control), .maskControl),
            (CGKeyCode(kVK_Shift), .maskShift),
        ].filter { flags.contains($0.1) }

        func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, autorepeat: Bool = false) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else { return }
            event.flags = flags
            if autorepeat {
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
            event.post(tap: .cghidEventTap)
        }

        // 修飾キーを押していく。押すたびにフラグが積み上がる（実際の打鍵と同じ）。
        var accumulated: CGEventFlags = []
        for (code, flag) in modifierKeys {
            accumulated.insert(flag)
            post(code, down: true, flags: accumulated)
            Thread.sleep(forTimeInterval: 0.01)
        }

        // **修飾キーは必ず離す。** 離さないまま抜けると利用者のキーボードが
        // 修飾キーを押したままの状態で残る。
        defer {
            var remaining = accumulated
            for (code, flag) in modifierKeys.reversed() {
                remaining.remove(flag)
                post(code, down: false, flags: remaining)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        var sent = 0
        for index in 0..<max(1, count) {
            post(keyCode, down: true, flags: flags, autorepeat: index > 0)
            sent += 1
            if interval > 0 {
                Thread.sleep(forTimeInterval: interval)
            }
        }
        post(keyCode, down: false, flags: flags)
        return sent
    }

    /// ポインタを動かす。座標は AX と同じ左上原点。**ボタンは押さない。**
    ///
    /// `focus-follows-mouse` の検証に使う。`CGWarpMouseCursorPosition` では
    /// 移動イベントが出ないので、乗ったことを知らせるには `mouseMoved` を送る必要がある。
    ///
    /// - Parameter steps: 途中の点も送る回数。1点だけだと、通り道にある
    ///   ウィンドウを跨いだことにならず、追従の判定を通らないことがある。
    public static func postMouseMove(
        to point: CGPoint, steps: Int = 3, interval: TimeInterval = 0.02
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<max(1, steps) {
            guard
                let event = CGEvent(
                    mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)
            else { return }
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// 指定座標から指定座標へドラッグする。座標は AX と同じ左上原点。
    ///
    /// ウィンドウの縁を掴むリサイズを再現するために使う。
    /// **`mouseDown` を押したままにする**ので、`CGEventSource.buttonState` から見ても
    /// 「利用者がドラッグしている」状態になる。
    public static func postDrag(
        from start: CGPoint,
        to end: CGPoint,
        steps: Int = 10,
        interval: TimeInterval = 0.02
    ) {
        let source = CGEventSource(stateID: .hidSystemState)

        func post(_ type: CGEventType, _ point: CGPoint) {
            guard
                let event = CGEvent(
                    mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                    mouseButton: .left)
            else { return }
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: interval)
        }

        // 掴む前にカーソルを縁へ置く。いきなり押すとアプリが取りこぼすことがある。
        post(.mouseMoved, start)
        post(.leftMouseDown, start)

        let count = max(1, steps)
        for step in 1...count {
            let ratio = CGFloat(step) / CGFloat(count)
            post(
                .leftMouseDragged,
                CGPoint(
                    x: start.x + (end.x - start.x) * ratio,
                    y: start.y + (end.y - start.y) * ratio))
        }
        post(.leftMouseUp, end)
    }
}
