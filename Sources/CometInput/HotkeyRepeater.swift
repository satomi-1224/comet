import Foundation

/// 押しっぱなしのあいだコマンドを繰り返す。
///
/// **Carbon の `kEventHotKeyPressed` はキー連射では繰り返し発火しない。**
/// 実測で、keyUp を挟まずに keyDown を 15 回送っても発火は 1 回だった。
/// つまり「`alt-ctrl-l` を押しっぱなしにしてリサイズを追従させる」は
/// ホットキーの発火だけでは実現できない。
///
/// そこで**離されるまで自分で繰り返す**。`CGEventTap` を使わないので
/// 入力監視（Input Monitoring）権限は要らない。
@MainActor
public final class HotkeyRepeater {

    /// 押してから繰り返しが始まるまで。短すぎると単押しでも2回動いて驚く。
    public var delay: TimeInterval
    /// 繰り返しの間隔。
    public var interval: TimeInterval

    private var active: [Hotkey: DispatchWorkItem] = [:]
    private var generation = 0

    public init(delay: TimeInterval = 0.25, interval: TimeInterval = 0.03) {
        self.delay = delay
        self.interval = interval
    }

    public var activeCount: Int { active.count }

    /// 押されたときに呼ぶ。**`action` はここでは実行しない**（押下時の1回目は
    /// 呼び出し側が既に実行しているため）。遅延のあと繰り返しを始める。
    public func begin(_ hotkey: Hotkey, action: @escaping @MainActor () -> Void) {
        cancel(hotkey)
        generation += 1
        schedule(hotkey, after: delay, generation: generation, action: action)
    }

    /// 離されたときに呼ぶ。
    public func end(_ hotkey: Hotkey) {
        cancel(hotkey)
    }

    public func stopAll() {
        for hotkey in active.keys {
            cancel(hotkey)
        }
    }

    private func schedule(
        _ hotkey: Hotkey, after wait: TimeInterval, generation: Int,
        action: @escaping @MainActor () -> Void
    ) {
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active[hotkey] != nil else { return }
                action()
                // 次の繰り返しを積む。離されると `end` が積むのを止める。
                self.schedule(
                    hotkey, after: self.interval, generation: generation, action: action)
            }
        }
        active[hotkey] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func cancel(_ hotkey: Hotkey) {
        active.removeValue(forKey: hotkey)?.cancel()
    }
}
