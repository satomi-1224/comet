import Testing

@testable import CometSupport

@Suite("LaunchOptions")
struct LaunchOptionsTests {

    @Test("引数なしなら既定値")
    func defaults() throws {
        let opts = try LaunchOptions.parse([])
        #expect(opts.logLevel == nil, "明示されていなければ指定なし")
        #expect(opts.resolvedLogLevel(configured: nil) == .info)
        #expect(opts.hotkeys.isEmpty)
        #expect(opts.showHelp == false)
        #expect(opts.printKeys == false)
        #expect(opts.configPath == nil)
        #expect(opts.ignoreConfig == false)
        #expect(opts.printDefaultConfig == false)
    }

    // 優先順位: コマンドライン > 設定ファイル > 既定。
    // 逆にすると `--log-level trace` でデバッグしようとしても設定に戻される。
    @Test("ログレベルはコマンドラインが設定ファイルより優先される")
    func logLevelPrecedence() throws {
        let explicit = try LaunchOptions.parse(["--log-level", "trace"])
        #expect(explicit.resolvedLogLevel(configured: .warn) == .trace)

        let implicit = try LaunchOptions.parse([])
        #expect(implicit.resolvedLogLevel(configured: .warn) == .warn)
    }

    @Test("--run を複数回指定できる")
    func runCommands() throws {
        let options = try LaunchOptions.parse([
            "--run", "workspace 2", "--run=move left", "--run", "focus right",
        ])
        #expect(options.commands == ["workspace 2", "move left", "focus right"])
        #expect(try LaunchOptions.parse([]).commands.isEmpty)
    }

    @Test("設定ファイルに関するオプションを解釈する")
    func configOptions() throws {
        #expect(try LaunchOptions.parse(["--config", "/tmp/a.toml"]).configPath == "/tmp/a.toml")
        #expect(try LaunchOptions.parse(["--config=/tmp/b.toml"]).configPath == "/tmp/b.toml")
        #expect(try LaunchOptions.parse(["--no-config"]).ignoreConfig)
        #expect(try LaunchOptions.parse(["--print-default-config"]).printDefaultConfig)
    }

    @Test("--log-level を解釈する")
    func logLevel() throws {
        #expect(try LaunchOptions.parse(["--log-level", "debug"]).logLevel == .debug)
        #expect(try LaunchOptions.parse(["--log-level", "TRACE"]).logLevel == .trace)
    }

    @Test("--log-level=value 形式も受け付ける")
    func logLevelEqualsForm() throws {
        #expect(try LaunchOptions.parse(["--log-level=warn"]).logLevel == .warn)
    }

    @Test("不正なログレベルはエラー")
    func invalidLogLevel() {
        #expect(throws: LaunchOptionsError.invalidLogLevel("chatty")) {
            try LaunchOptions.parse(["--log-level", "chatty"])
        }
    }

    @Test("値が欠けていればエラー")
    func missingValue() {
        #expect(throws: LaunchOptionsError.missingValue(flag: "--log-level")) {
            try LaunchOptions.parse(["--log-level"])
        }
    }

    // 「--log-level --hotkey alt-h」のように値の位置に別のフラグが来た場合、
    // "--hotkey" を値として飲み込むと診断不能な設定ミスになる。欠落として扱う。
    @Test("値の位置に別のフラグが来たら欠落として扱う")
    func flagInValuePosition() {
        #expect(throws: LaunchOptionsError.missingValue(flag: "--log-level")) {
            try LaunchOptions.parse(["--log-level", "--hotkey", "alt-h"])
        }
    }

    // "--log-level=" を「不正な値」と報告すると『不正なログレベル: 』という
    // 中身のない診断になる。欠落として扱うほうが原因が分かる。
    @Test("--flag= の空値は欠落として扱う")
    func emptyValueInEqualsForm() {
        #expect(throws: LaunchOptionsError.missingValue(flag: "--log-level")) {
            try LaunchOptions.parse(["--log-level="])
        }
        #expect(throws: LaunchOptionsError.missingValue(flag: "--hotkey")) {
            try LaunchOptions.parse(["--hotkey="])
        }
    }

    @Test("=形式でも未知のフラグはエラー")
    func unknownFlagInEqualsForm() {
        #expect(throws: LaunchOptionsError.unknownFlag("--turbo")) {
            try LaunchOptions.parse(["--turbo=1"])
        }
    }

    @Test("--hotkey は繰り返し指定できる")
    func repeatedHotkeys() throws {
        let opts = try LaunchOptions.parse(["--hotkey", "alt-h", "--hotkey", "alt-l"])
        #expect(opts.hotkeys == ["alt-h", "alt-l"])
    }

    @Test("--help と --print-keys はフラグ")
    func boolFlags() throws {
        #expect(try LaunchOptions.parse(["--help"]).showHelp)
        #expect(try LaunchOptions.parse(["-h"]).showHelp)
        #expect(try LaunchOptions.parse(["--print-keys"]).printKeys)
    }

    // 他の WM が動いている状態でも、レイアウト計算だけを検証できるようにする。
    @Test("--dry-run はウィンドウを動かさない指定")
    func dryRunFlag() throws {
        #expect(try LaunchOptions.parse([]).dryRun == false)
        #expect(try LaunchOptions.parse(["--dry-run"]).dryRun)
    }

    @Test("--preview-layout は枚数を取る")
    func previewLayoutFlag() throws {
        #expect(try LaunchOptions.parse([]).previewLayout == nil)
        #expect(try LaunchOptions.parse(["--preview-layout", "5"]).previewLayout == 5)
        #expect(try LaunchOptions.parse(["--preview-layout=3"]).previewLayout == 3)
    }

    @Test("--preview-layout に 1 未満や非数値はエラー")
    func previewLayoutRejectsInvalidCounts() {
        #expect(throws: LaunchOptionsError.invalidWindowCount("0")) {
            try LaunchOptions.parse(["--preview-layout", "0"])
        }
        #expect(throws: LaunchOptionsError.invalidWindowCount("abc")) {
            try LaunchOptions.parse(["--preview-layout", "abc"])
        }
    }

    @Test("未知のフラグはエラー")
    func unknownFlag() {
        #expect(throws: LaunchOptionsError.unknownFlag("--turbo")) {
            try LaunchOptions.parse(["--turbo"])
        }
    }

    // フラグでない裸の引数を黙って捨てると、打ち間違いが無言で無視される。
    @Test("位置引数はエラー")
    func positionalArgument() {
        #expect(throws: LaunchOptionsError.unexpectedArgument("oops")) {
            try LaunchOptions.parse(["oops"])
        }
    }

    @Test("エラーは説明文に原因の文字列を含む")
    func errorDescriptions() {
        #expect(LaunchOptionsError.unknownFlag("--turbo").description.contains("--turbo"))
        #expect(LaunchOptionsError.invalidLogLevel("chatty").description.contains("chatty"))
        #expect(LaunchOptionsError.missingValue(flag: "--log-level").description.contains("--log-level"))
        #expect(LaunchOptionsError.unexpectedArgument("oops").description.contains("oops"))
    }

    @Test("usage は全フラグに言及する")
    func usageMentionsEveryFlag() {
        let usage = LaunchOptions.usage
        for flag in ["--log-level", "--hotkey", "--print-keys", "--help"] {
            #expect(usage.contains(flag), "usage に \(flag) の記載がない")
        }
    }
}
