import Carbon.HIToolbox
import Foundation

public enum KeySpecError: Error, Equatable, CustomStringConvertible {
    case empty
    case emptyComponent(spec: String)
    case unknownModifier(String, spec: String)
    case duplicateModifier(String, spec: String)
    case modifierUsedAsKey(String, spec: String)
    case unknownKey(String, spec: String)

    public var description: String {
        switch self {
        case .empty:
            "ホットキーの指定が空"
        case .emptyComponent(let spec):
            "\"\(spec)\": 空の要素がある。'-' 自体を指定したい場合は minus と綴る"
        case .unknownModifier(let token, let spec):
            "\"\(spec)\": 未知の修飾キー \"\(token)\"（有効: cmd, alt, ctrl, shift）"
        case .duplicateModifier(let token, let spec):
            "\"\(spec)\": 修飾キー \"\(token)\" が重複している"
        case .modifierUsedAsKey(let token, let spec):
            "\"\(spec)\": \"\(token)\" は修飾キーでありキーではない。末尾にキーを指定する"
        case .unknownKey(let token, let spec):
            "\"\(spec)\": 未知のキー \"\(token)\"（--print-keys で一覧を確認できる）"
        }
    }
}

/// `"alt-shift-h"` のような文字列を ``Hotkey`` に変換する。
///
/// 設定ファイルとコマンドライン引数の両方から使うため、
/// 副作用のない純粋なパーサとして独立させてある。
public enum KeySpec {

    // MARK: - 修飾キー

    private static let modifierTable: [String: UInt32] = [
        "cmd": UInt32(cmdKey),
        "command": UInt32(cmdKey),
        "alt": UInt32(optionKey),
        "opt": UInt32(optionKey),
        "option": UInt32(optionKey),
        "ctrl": UInt32(controlKey),
        "control": UInt32(controlKey),
        "shift": UInt32(shiftKey),
    ]

    /// 別名で書かれていても同じ名前で報告できるようにする。
    private static func canonicalModifierName(_ bit: UInt32) -> String {
        switch bit {
        case UInt32(cmdKey): "cmd"
        case UInt32(optionKey): "alt"
        case UInt32(controlKey): "ctrl"
        case UInt32(shiftKey): "shift"
        default: "unknown"
        }
    }

    // MARK: - キー

    /// 正式名とキーコードの対応。値は Carbon の定数から取る（数値をハードコードしない）。
    private static let canonicalKeys: [(String, Int)] = [
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
        ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
        ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
        ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
        ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
        ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
        ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),

        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
        ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),

        ("minus", kVK_ANSI_Minus), ("equal", kVK_ANSI_Equal),
        ("leftbracket", kVK_ANSI_LeftBracket), ("rightbracket", kVK_ANSI_RightBracket),
        ("backslash", kVK_ANSI_Backslash), ("semicolon", kVK_ANSI_Semicolon),
        ("quote", kVK_ANSI_Quote), ("comma", kVK_ANSI_Comma),
        ("period", kVK_ANSI_Period), ("slash", kVK_ANSI_Slash),
        ("grave", kVK_ANSI_Grave),

        ("return", kVK_Return), ("tab", kVK_Tab), ("space", kVK_Space),
        ("delete", kVK_Delete), ("forwarddelete", kVK_ForwardDelete),
        ("escape", kVK_Escape), ("keypadenter", kVK_ANSI_KeypadEnter),

        ("home", kVK_Home), ("end", kVK_End),
        ("pageup", kVK_PageUp), ("pagedown", kVK_PageDown),
        ("left", kVK_LeftArrow), ("right", kVK_RightArrow),
        ("up", kVK_UpArrow), ("down", kVK_DownArrow),

        ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
        ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8),
        ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
        ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15), ("f16", kVK_F16),
        ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19), ("f20", kVK_F20),
    ]

    /// 別名 → 正式名。記号のリテラル表記もここで吸収する。
    /// "-" は区切り文字なのでリテラルでは書けない（"minus" と綴る）。
    private static let keyAliases: [String: String] = [
        "enter": "return",
        "esc": "escape",
        "backspace": "delete",
        ";": "semicolon",
        "/": "slash",
        ",": "comma",
        ".": "period",
        "'": "quote",
        "`": "grave",
        "[": "leftbracket",
        "]": "rightbracket",
        "=": "equal",
        "\\": "backslash",
    ]

    private static let keyTable: [String: UInt32] = {
        var table: [String: UInt32] = [:]
        for (name, code) in canonicalKeys {
            table[name] = UInt32(code)
        }
        for (alias, canonical) in keyAliases {
            if let code = table[canonical] {
                table[alias] = code
            }
        }
        return table
    }()

    private static let nameByKeyCode: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        for (name, code) in canonicalKeys {
            table[UInt32(code)] = name
        }
        return table
    }()

    /// 修飾キーなしで奪うと通常の文字入力を潰してしまうキー。
    private static let typingKeyCodes: Set<UInt32> = {
        var codes = Set<UInt32>()
        for (name, code) in canonicalKeys {
            let isFunctionKey = name.first == "f" && name.count > 1 && name.dropFirst().allSatisfy(\.isNumber)
            let isNavigation = [
                "left", "right", "up", "down", "home", "end", "pageup", "pagedown",
                "escape", "forwarddelete",
            ].contains(name)
            if !isFunctionKey && !isNavigation {
                codes.insert(UInt32(code))
            }
        }
        return codes
    }()

    /// `--print-keys` 用。別名も含む全ての受理可能なキー名。
    public static let knownKeyNames: [String] = keyTable.keys.sorted()

    /// キーコードから正式名を引く。ログ表示用。
    public static func name(forKeyCode code: UInt32) -> String? {
        nameByKeyCode[code]
    }

    // MARK: - パース

    public static func parse(_ spec: String) throws -> Hotkey {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeySpecError.empty }

        let components = trimmed.lowercased()
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)

        guard components.allSatisfy({ !$0.isEmpty }) else {
            throw KeySpecError.emptyComponent(spec: trimmed)
        }

        var modifiers: UInt32 = 0
        for token in components.dropLast() {
            guard let bit = modifierTable[token] else {
                throw KeySpecError.unknownModifier(token, spec: trimmed)
            }
            guard modifiers & bit == 0 else {
                throw KeySpecError.duplicateModifier(canonicalModifierName(bit), spec: trimmed)
            }
            modifiers |= bit
        }

        // components は空要素を持たないことを確認済みなので last は必ず存在する
        let keyToken = components[components.count - 1]

        guard let keyCode = keyTable[keyToken] else {
            // "alt-shift" のように修飾キー名で終わっている場合は、
            // 単なる未知のキーより踏み込んだ診断を出す
            if let bit = modifierTable[keyToken] {
                throw KeySpecError.modifierUsedAsKey(canonicalModifierName(bit), spec: trimmed)
            }
            throw KeySpecError.unknownKey(keyToken, spec: trimmed)
        }

        return Hotkey(keyCode: keyCode, modifiers: modifiers)
    }

    /// 登録すると通常のキー入力を全アプリから奪ってしまう可能性があるか。
    ///
    /// `RegisterEventHotKey` は修飾キーなしの登録も受け付けてしまうため、
    /// 呼び出し側が警告を出せるように判定だけ提供する。
    /// shift のみでは大文字入力を潰すので「安全」には数えない。
    public static func isRisky(_ hotkey: Hotkey) -> Bool {
        let strongModifiers = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard hotkey.modifiers & strongModifiers == 0 else { return false }
        return typingKeyCodes.contains(hotkey.keyCode)
    }
}
