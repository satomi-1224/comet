import Testing
import CometConfig

/// 項目名の綴りの照合。
///
/// **`Decodable` は知らないキーを黙って捨てる。** 照合しないと
/// 「設定したのに効かない」だけが残り、打ち間違いなのか未対応なのかも分からない。
@Suite("設定の項目名の照合")
struct ConfigSchemaTests {

    private func unknownDetails(_ toml: String) throws -> [String] {
        try ConfigLoader.parse(toml).problems
            .filter { $0.kind == .unknownKey }
            .map(\.detail)
    }

    // これが落ちるなら、既定の設定と照合表のどちらかが古い。
    @Test("既定の設定に知らない項目は無い")
    func defaultConfigurationIsFullyKnown() throws {
        let problems = ConfigLoader.builtIn().problems.filter { $0.kind == .unknownKey }
        #expect(problems.isEmpty, "\(problems.map(\.detail))")
    }

    @Test("表の中の綴り間違いを見つける")
    func detectsMisspelledKey() throws {
        let details = try unknownDetails("[gaps]\ninner = 5")
        #expect(details.count == 1)
        #expect(details[0].contains("[gaps] inner"))
    }

    @Test("近い綴りがあれば候補を添える")
    func suggestsCloseName() throws {
        let details = try unknownDetails("[gaps]\ninner-horizonal = 5")
        #expect(details.count == 1)
        #expect(details[0].contains("inner-horizontal"), "\(details[0])")
    }

    @Test("見当違いの候補は出さない")
    func doesNotSuggestUnrelatedName() throws {
        let details = try unknownDetails("[gaps]\nzzzzzzzzzzzz = 5")
        #expect(details.count == 1)
        #expect(!details[0].contains("綴り間違い"), "\(details[0])")
    }

    @Test("知らないセクションを見つける")
    func detectsUnknownSection() throws {
        let details = try unknownDetails("[borders]\nwidth = 2")
        #expect(details.contains { $0.contains("borders") })
    }

    @Test("キーバインドの綴りは自由なので何も言わない")
    func bindingNamesAreFree() throws {
        let details = try unknownDetails(
            """
            [mode.main.binding]
            alt-h = "focus left"
            [mode.resize.binding]
            h = "resize width -50"
            """)
        #expect(details.isEmpty, "\(details)")
    }

    @Test("ワークスペース番号のキーは自由")
    func workspaceKeysAreFree() throws {
        let details = try unknownDetails(
            """
            [wallpaper.map]
            1 = "/tmp/a.png"
            [workspaces.names]
            2 = "code"
            """)
        #expect(details.isEmpty, "\(details)")
    }

    @Test("表の配列の中も照合する")
    func checksInsideArrayOfTables() throws {
        let details = try unknownDetails(
            """
            [[window-rule]]
            if-app-id = "com.example.app"
            run = "layout floating"

            [[window-rule]]
            if-app-name = "Example"
            run = "layout floating"
            """)
        #expect(details.contains { $0.contains("if-app-name") }, "\(details)")
    }

    // 値のはずの場所に表を書くと、読み込みそのものが失敗する。
    // `load()` はそれを `.unreadable` として伝え、既定の設定で起動する。
    @Test("値の下に表を書いたら読み込みが失敗する")
    func aTableUnderAValueFailsToLoad() {
        #expect(throws: (any Error).self) { try ConfigLoader.parse("[monitors.manage]\nall = true") }
    }

    @Test("壊れた TOML では何も言わない（本体が同じ誤りを報告する）")
    func brokenTOMLIsLeftToTheLoader() {
        #expect(throws: (any Error).self) { try ConfigLoader.parse("[gaps") }
    }
}

/// 新しく足した設定項目が実際に読めるか。
///
/// **`ConfigSchema` に足しただけでは効かない。** 照合表と読み込みの両方が
/// 揃っていることをここで固定する（片方だけ直しても気付けるように）。
@Suite("後から足した設定項目")
struct NewOptionTests {

    @Test("ポインタへの追従と端での巻き戻しを読める")
    func focusOptions() throws {
        let configuration = try ConfigLoader.parse(
            """
            [focus]
            follows-mouse = true
            wrapping = true
            """)
        #expect(configuration.focusFollowsMouse)
        #expect(configuration.focusWrapping)
        #expect(!configuration.problems.contains { $0.kind == .unknownKey })
    }

    @Test("既定はどちらも無効（i3 とは違う）")
    func focusOptionDefaults() throws {
        let configuration = ConfigLoader.builtIn()
        #expect(!configuration.focusFollowsMouse)
        #expect(!configuration.focusWrapping)
    }

    @Test("同じ番号での往復を読める")
    func autoBackAndForth() throws {
        let configuration = try ConfigLoader.parse("[workspaces]\nauto-back-and-forth = true")
        #expect(configuration.workspaceAutoBackAndForth)
        #expect(!configuration.problems.contains { $0.kind == .unknownKey })
    }

    @Test("ワークスペースの名前を読める")
    func workspaceNames() throws {
        let configuration = try ConfigLoader.parse(
            """
            [workspaces.names]
            1 = "web"
            3 = "code"
            """)
        #expect(configuration.workspaceNames == [1: "web", 3: "code"])
        #expect(!configuration.problems.contains { $0.kind == .unknownKey })
    }

    @Test("名前のキーが番号でなければ問題として記録する")
    func workspaceNameKeyMustBeANumber() throws {
        let configuration = try ConfigLoader.parse(
            """
            [workspaces.names]
            web = "web"
            """)
        #expect(configuration.workspaceNames.isEmpty)
        #expect(configuration.problems.contains { $0.kind == .invalidValue })
    }
}
