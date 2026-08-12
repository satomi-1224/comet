import Carbon.HIToolbox
import Testing

@testable import CometInput

private let cmd = UInt32(cmdKey)
private let shift = UInt32(shiftKey)
private let alt = UInt32(optionKey)
private let ctrl = UInt32(controlKey)

@Suite("KeySpec のパース")
struct KeySpecTests {

    // MARK: - 基本

    @Test("修飾キー1つ + 文字キー")
    func singleModifier() throws {
        let hk = try KeySpec.parse("alt-h")
        #expect(hk.keyCode == UInt32(kVK_ANSI_H))
        #expect(hk.modifiers == alt)
    }

    @Test("修飾キー複数はビット和になる")
    func multipleModifiers() throws {
        let hk = try KeySpec.parse("cmd-alt-shift-space")
        #expect(hk.keyCode == UInt32(kVK_Space))
        #expect(hk.modifiers == cmd | alt | shift)
    }

    @Test("修飾キーの順序は結果に影響しない")
    func modifierOrderIrrelevant() throws {
        #expect(try KeySpec.parse("alt-shift-h") == KeySpec.parse("shift-alt-h"))
        #expect(try KeySpec.parse("cmd-ctrl-a") == KeySpec.parse("ctrl-cmd-a"))
    }

    @Test("大文字小文字を無視する")
    func caseInsensitive() throws {
        #expect(try KeySpec.parse("Alt-Shift-H") == KeySpec.parse("alt-shift-h"))
        #expect(try KeySpec.parse("CMD-SPACE") == KeySpec.parse("cmd-space"))
    }

    @Test("前後の空白を無視する")
    func trimsWhitespace() throws {
        #expect(try KeySpec.parse("  alt-h \n") == KeySpec.parse("alt-h"))
    }

    @Test("修飾キーなしも解釈できる")
    func noModifier() throws {
        let hk = try KeySpec.parse("f1")
        #expect(hk.keyCode == UInt32(kVK_F1))
        #expect(hk.modifiers == 0)
    }

    // MARK: - 修飾キーの別名

    @Test(
        "修飾キーの別名",
        arguments: [
            ("cmd-a", cmd), ("command-a", cmd),
            ("alt-a", alt), ("opt-a", alt), ("option-a", alt),
            ("ctrl-a", ctrl), ("control-a", ctrl),
            ("shift-a", shift),
        ])
    func modifierAliases(spec: String, expected: UInt32) throws {
        #expect(try KeySpec.parse(spec).modifiers == expected)
    }

    // MARK: - キー名

    @Test(
        "現行設定で使う名前付きキー",
        arguments: [
            ("semicolon", kVK_ANSI_Semicolon),
            ("slash", kVK_ANSI_Slash),
            ("return", kVK_Return),
            ("enter", kVK_Return),
            ("tab", kVK_Tab),
            ("space", kVK_Space),
            ("delete", kVK_Delete),
            ("backspace", kVK_Delete),
            ("forwarddelete", kVK_ForwardDelete),
            ("escape", kVK_Escape),
            ("esc", kVK_Escape),
            ("minus", kVK_ANSI_Minus),
            ("equal", kVK_ANSI_Equal),
            ("comma", kVK_ANSI_Comma),
            ("period", kVK_ANSI_Period),
            ("grave", kVK_ANSI_Grave),
            ("quote", kVK_ANSI_Quote),
            ("backslash", kVK_ANSI_Backslash),
            ("leftbracket", kVK_ANSI_LeftBracket),
            ("rightbracket", kVK_ANSI_RightBracket),
            ("left", kVK_LeftArrow),
            ("right", kVK_RightArrow),
            ("up", kVK_UpArrow),
            ("down", kVK_DownArrow),
        ])
    func namedKeys(name: String, code: Int) throws {
        #expect(try KeySpec.parse("alt-\(name)").keyCode == UInt32(code))
    }

    // 記号はリテラルでも書けるようにする。ただし "-" は区切り文字なので "minus" と綴る。
    @Test(
        "記号キーはリテラルでも書ける",
        arguments: [
            (";", kVK_ANSI_Semicolon), ("/", kVK_ANSI_Slash), (",", kVK_ANSI_Comma),
            (".", kVK_ANSI_Period), ("'", kVK_ANSI_Quote), ("`", kVK_ANSI_Grave),
            ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
            ("=", kVK_ANSI_Equal), ("\\", kVK_ANSI_Backslash),
        ])
    func literalSymbols(symbol: String, code: Int) throws {
        #expect(try KeySpec.parse("alt-\(symbol)").keyCode == UInt32(code))
    }

    @Test("数字キー 0-9")
    func digits() throws {
        let expected = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        for (name, code) in expected {
            #expect(try KeySpec.parse("alt-\(name)").keyCode == UInt32(code), "キー \(name)")
        }
    }

    @Test("ファンクションキー f1-f20")
    func functionKeys() throws {
        // 番号順に並んでいないので、代表値を実際の定数と突き合わせる
        #expect(try KeySpec.parse("f1").keyCode == UInt32(kVK_F1))
        #expect(try KeySpec.parse("f5").keyCode == UInt32(kVK_F5))
        #expect(try KeySpec.parse("f12").keyCode == UInt32(kVK_F12))
        #expect(try KeySpec.parse("f20").keyCode == UInt32(kVK_F20))
    }

    @Test("f21 は存在しない")
    func functionKeyOutOfRange() {
        #expect(throws: KeySpecError.unknownKey("f21", spec: "f21")) {
            try KeySpec.parse("f21")
        }
    }

    // MARK: - 現行 AeroSpace 設定の全バインドが解釈できること

    @Test(
        "現行設定のバインドを全て解釈できる",
        arguments: [
            "alt-1", "alt-2", "alt-3", "alt-4", "alt-5",
            "alt-6", "alt-7", "alt-8", "alt-9", "alt-0",
            "alt-shift-1", "alt-shift-2", "alt-shift-3", "alt-shift-4", "alt-shift-5",
            "alt-shift-6", "alt-shift-7", "alt-shift-8", "alt-shift-9", "alt-shift-0",
            "alt-h", "alt-j", "alt-k", "alt-l",
            "alt-shift-h", "alt-shift-j", "alt-shift-k", "alt-shift-l",
            "alt-ctrl-h", "alt-ctrl-j", "alt-ctrl-k", "alt-ctrl-l",
            "alt-semicolon", "alt-s", "alt-a", "alt-slash", "alt-shift-f",
            "alt-e", "alt-w",
            // 今後追加する予定のもの
            "alt-shift-delete", "alt-tab", "alt-r",
        ])
    func currentConfigBindings(spec: String) throws {
        _ = try KeySpec.parse(spec)
    }

    // MARK: - エラー

    @Test("空文字はエラー")
    func emptySpec() {
        #expect(throws: KeySpecError.empty) { try KeySpec.parse("") }
        #expect(throws: KeySpecError.empty) { try KeySpec.parse("   ") }
    }

    @Test("空の要素はエラー")
    func emptyComponent() {
        #expect(throws: KeySpecError.emptyComponent(spec: "alt-")) { try KeySpec.parse("alt-") }
        #expect(throws: KeySpecError.emptyComponent(spec: "-h")) { try KeySpec.parse("-h") }
        #expect(throws: KeySpecError.emptyComponent(spec: "alt--h")) { try KeySpec.parse("alt--h") }
    }

    // 重複はほぼ確実に打ち間違い（alt-alt-h は alt-cmd-h の書き損じ等）なので通さない。
    @Test("修飾キーの重複はエラー")
    func duplicateModifier() {
        #expect(throws: KeySpecError.duplicateModifier("alt", spec: "alt-alt-h")) {
            try KeySpec.parse("alt-alt-h")
        }
        // 別名同士の重複も検出する
        #expect(throws: KeySpecError.duplicateModifier("alt", spec: "alt-option-h")) {
            try KeySpec.parse("alt-option-h")
        }
    }

    @Test("未知の修飾キーはエラー")
    func unknownModifier() {
        #expect(throws: KeySpecError.unknownModifier("hyper", spec: "hyper-h")) {
            try KeySpec.parse("hyper-h")
        }
    }

    @Test("未知のキーはエラー")
    func unknownKey() {
        #expect(throws: KeySpecError.unknownKey("foo", spec: "alt-foo")) {
            try KeySpec.parse("alt-foo")
        }
    }

    // "alt-shift" は「shift キーを押す」ではなく修飾キーの書き忘れ。
    // 単なる unknownKey より踏み込んだ診断を出す。
    @Test("末尾が修飾キー名なら専用のエラーになる")
    func modifierUsedAsKey() {
        #expect(throws: KeySpecError.modifierUsedAsKey("shift", spec: "alt-shift")) {
            try KeySpec.parse("alt-shift")
        }
        #expect(throws: KeySpecError.modifierUsedAsKey("cmd", spec: "cmd")) {
            try KeySpec.parse("cmd")
        }
    }

    @Test("エラーの説明文は元の指定文字列を含む")
    func errorDescriptionsIncludeSpec() {
        let cases: [KeySpecError] = [
            .emptyComponent(spec: "alt-"),
            .unknownModifier("hyper", spec: "hyper-h"),
            .duplicateModifier("alt", spec: "alt-alt-h"),
            .modifierUsedAsKey("shift", spec: "alt-shift"),
            .unknownKey("foo", spec: "alt-foo"),
        ]
        for error in cases {
            #expect(!error.description.isEmpty)
        }
        #expect(KeySpecError.unknownKey("foo", spec: "alt-foo").description.contains("alt-foo"))
        #expect(KeySpecError.unknownKey("foo", spec: "alt-foo").description.contains("foo"))
    }

    // MARK: - 危険なバインドの検出

    // 修飾キーなしで文字キーを奪うと、そのキーが全アプリで打てなくなる。
    // パーサは通すが、登録側が警告を出せるよう判定を提供する。
    @Test("修飾キーなしの文字キーは危険")
    func riskyBindings() throws {
        #expect(KeySpec.isRisky(try KeySpec.parse("h")))
        #expect(KeySpec.isRisky(try KeySpec.parse("1")))
        #expect(KeySpec.isRisky(try KeySpec.parse("space")))
        #expect(KeySpec.isRisky(try KeySpec.parse("return")))
        // shift だけでは通常の入力（大文字）を奪うので依然として危険
        #expect(KeySpec.isRisky(try KeySpec.parse("shift-h")))
    }

    @Test("ファンクションキーと矢印は修飾キーなしでも安全")
    func nonRiskyBindings() throws {
        #expect(!KeySpec.isRisky(try KeySpec.parse("f1")))
        #expect(!KeySpec.isRisky(try KeySpec.parse("f13")))
        #expect(!KeySpec.isRisky(try KeySpec.parse("left")))
        #expect(!KeySpec.isRisky(try KeySpec.parse("escape")))
    }

    @Test("cmd/alt/ctrl のいずれかが付けば安全")
    func modifiedBindingsAreSafe() throws {
        #expect(!KeySpec.isRisky(try KeySpec.parse("alt-h")))
        #expect(!KeySpec.isRisky(try KeySpec.parse("cmd-h")))
        #expect(!KeySpec.isRisky(try KeySpec.parse("ctrl-h")))
        #expect(!KeySpec.isRisky(try KeySpec.parse("cmd-shift-h")))
    }

    // MARK: - 表記の往復

    // Hotkey.description はログとエラーメッセージに出る。
    // それを再びパースできなければ、ログを見て設定を直す作業が成立しない。
    @Test(
        "description はパースし直せる",
        arguments: [
            "alt-h", "alt-shift-l", "cmd-alt-shift-space", "ctrl-alt-shift-q",
            "alt-semicolon", "alt-slash", "f1", "alt-1", "cmd-ctrl-alt-shift-tab",
        ])
    func descriptionRoundTrips(spec: String) throws {
        let hotkey = try KeySpec.parse(spec)
        #expect(try KeySpec.parse(hotkey.description) == hotkey)
    }

    @Test("未知のキーコードでも description は落ちない")
    func descriptionForUnknownKeyCode() {
        let hotkey = Hotkey(keyCode: 0xFFFF, modifiers: 0)
        #expect(!hotkey.description.isEmpty)
    }

    // キーコード → 名前の逆引き表は正式名を上書きしながら作るため、
    // 表にキーコードの重複があると description が別のキー名を返すようになる。
    // 全キーの往復を確認することで、重複と逆引き漏れの両方を検出する。
    @Test("全ての既知キーは description 経由で往復する")
    func everyKnownKeyRoundTrips() throws {
        for name in KeySpec.knownKeyNames {
            let hotkey = try KeySpec.parse("alt-\(name)")
            let reparsed = try KeySpec.parse(hotkey.description)
            #expect(
                reparsed == hotkey,
                "\"\(name)\" が往復しない: description=\"\(hotkey.description)\"")
        }
    }

    // MARK: - キー名一覧

    @Test("キー名一覧は重複がなくソート済み")
    func knownKeyNamesAreCleanAndSorted() {
        let names = KeySpec.knownKeyNames
        #expect(!names.isEmpty)
        #expect(Set(names).count == names.count, "重複がある")
        #expect(names == names.sorted(), "ソートされていない")
    }

    @Test("一覧に載っている名前は全てパースできる")
    func everyListedNameParses() throws {
        for name in KeySpec.knownKeyNames {
            _ = try KeySpec.parse("alt-\(name)")
        }
    }
}
