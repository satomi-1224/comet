import Foundation
import Testing
import CometInput

/// 押しっぱなしのあいだコマンドを繰り返す仕掛け。
///
/// **Carbon の `kEventHotKeyPressed` はキー連射では繰り返し発火しない**（実測で
/// keyUp を挟まずに keyDown を 15 回送っても発火は 1 回）。押しっぱなしでの
/// 追従はここが担う。
@Suite("HotkeyRepeater")
@MainActor
struct HotkeyRepeaterTests {

    private let hotkey = Hotkey(keyCode: 4, modifiers: 0)

    @Test("遅延の前は繰り返さない")
    func waitsForTheDelay() async throws {
        let repeater = HotkeyRepeater(delay: 0.2, interval: 0.02)
        let counter = Counter()
        repeater.begin(hotkey) { counter.increment() }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(counter.value == 0, "短押しで2回動くと驚く")
        repeater.end(hotkey)
    }

    @Test("遅延のあと間隔ごとに繰り返す")
    func repeatsAfterTheDelay() async throws {
        let repeater = HotkeyRepeater(delay: 0.05, interval: 0.02)
        let counter = Counter()
        repeater.begin(hotkey) { counter.increment() }
        try await Task.sleep(nanoseconds: 300_000_000)
        repeater.end(hotkey)
        #expect(counter.value >= 3, "繰り返しが始まっていない（\(counter.value) 回）")
    }

    @Test("離すと止まる")
    func stopsOnRelease() async throws {
        let repeater = HotkeyRepeater(delay: 0.05, interval: 0.02)
        let counter = Counter()
        repeater.begin(hotkey) { counter.increment() }
        try await Task.sleep(nanoseconds: 200_000_000)
        repeater.end(hotkey)
        let atRelease = counter.value
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(counter.value == atRelease, "離しても繰り返しが続いている")
        #expect(repeater.activeCount == 0)
    }

    // コマンドによって適切な速さが違う。`resize` は速く、`focus` は緩く。
    @Test("押下ごとに間隔を上げ下げできる")
    func perPressInterval() async throws {
        let repeater = HotkeyRepeater(delay: 0.05, interval: 0.01)
        let fast = Counter()
        let slow = Counter()
        let other = Hotkey(keyCode: 5, modifiers: 0)

        repeater.begin(hotkey) { fast.increment() }
        repeater.begin(other, interval: 0.15) { slow.increment() }
        try await Task.sleep(nanoseconds: 400_000_000)
        repeater.stopAll()

        #expect(fast.value > slow.value, "指定した間隔が効いていない（\(fast.value) / \(slow.value)）")
        #expect(slow.value >= 1, "緩めた側が一度も動かなかった")
    }

    @Test("同じキーを押し直したら数え直す")
    func reBeginResets() async throws {
        let repeater = HotkeyRepeater(delay: 0.15, interval: 0.02)
        let counter = Counter()
        repeater.begin(hotkey) { counter.increment() }
        try await Task.sleep(nanoseconds: 100_000_000)
        repeater.begin(hotkey) { counter.increment() }
        try await Task.sleep(nanoseconds: 100_000_000)
        repeater.end(hotkey)
        #expect(counter.value == 0, "押し直しで遅延が数え直されていない")
    }

    @Test("全部止められる")
    func stopAll() async throws {
        let repeater = HotkeyRepeater(delay: 0.05, interval: 0.02)
        repeater.begin(hotkey) {}
        repeater.begin(Hotkey(keyCode: 5, modifiers: 0)) {}
        #expect(repeater.activeCount == 2)
        repeater.stopAll()
        #expect(repeater.activeCount == 0)
    }

    /// 数えるだけの入れ物。メインアクター上でしか触らない。
    @MainActor
    private final class Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
