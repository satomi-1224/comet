import Carbon.HIToolbox

/// Carbon の `RegisterEventHotKey` にそのまま渡せる形のホットキー。
///
/// `modifiers` は Carbon の修飾キービット（`cmdKey` / `shiftKey` / `optionKey` / `controlKey`）
/// のビット和であり、AppKit の `NSEvent.ModifierFlags` とは別物なので混同しないこと。
public struct Hotkey: Hashable, Sendable, CustomStringConvertible {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ログ表示用の正規化された表記。修飾キーの並びは cmd → alt → ctrl → shift で固定する。
    public var description: String {
        var parts: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { parts.append("cmd") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("alt") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        parts.append(KeySpec.name(forKeyCode: keyCode) ?? "key(0x\(String(keyCode, radix: 16)))")
        return parts.joined(separator: "-")
    }
}
