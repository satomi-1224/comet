import Testing

@testable import CometInput
@testable import CometSupport

/// Carbon にホットキーを実際に登録するとテスト実行中にシステム全体のキーを奪ってしまうため、
/// ここでは Carbon に触れない経路だけを検証する。実登録の確認は手動検証で行う。
@MainActor
@Suite("HotkeyManager")
struct HotkeyManagerTests {

    /// テスト中にログを標準エラーへ吐かせない。
    private func quietLog() -> Log {
        let log = Log()
        log.threshold = .off
        return log
    }

    @Test("生成直後は未起動で登録数ゼロ")
    func initialState() {
        let manager = HotkeyManager(log: quietLog())
        #expect(manager.isRunning == false)
        #expect(manager.registeredCount == 0)
    }

    // start() を呼ばずに register() すると RegisterEventHotKey 自体は成功してしまい、
    // そのキーがシステム全体から奪われる一方で配送先が無い。
    // 「そのキーだけ無反応になる」という追跡困難な状態を作らないための防御。
    @Test("start() 前の register() は notStarted で弾く")
    func registerBeforeStartIsRejected() throws {
        let manager = HotkeyManager(log: quietLog())
        let hotkey = try KeySpec.parse("ctrl-alt-shift-f13")
        #expect(throws: HotkeyManager.ManagerError.notStarted) {
            try manager.register(hotkey) { _ in }
        }
        #expect(manager.registeredCount == 0)
    }

    @Test("未起動でも stop() は無害")
    func stopWithoutStartIsHarmless() {
        let manager = HotkeyManager(log: quietLog())
        manager.stop()
        #expect(manager.isRunning == false)
    }

    @Test("登録が無い状態の unregisterAll() は無害")
    func unregisterAllWhenEmptyIsHarmless() {
        let manager = HotkeyManager(log: quietLog())
        manager.unregisterAll()
        #expect(manager.registeredCount == 0)
    }

    @Test("エラーの説明文は対象のホットキーに言及する")
    func errorDescriptionsMentionHotkey() throws {
        let hotkey = try KeySpec.parse("alt-shift-h")
        let rendered = hotkey.description

        let cases: [HotkeyManager.ManagerError] = [
            .alreadyRegistered(hotkey),
            .takenByAnotherProcess(hotkey),
            .registrationFailed(hotkey, -1),
        ]
        for error in cases {
            #expect(error.description.contains(rendered), "\(error) が \(rendered) を含まない")
        }
    }

    @Test("他プロセスに奪われている場合の説明文は原因アプリを示唆する")
    func conflictErrorSuggestsCulprits() throws {
        let error = HotkeyManager.ManagerError.takenByAnotherProcess(try KeySpec.parse("alt-1"))
        #expect(error.description.contains("AeroSpace"))
    }

    @Test("notStarted の説明文は空でない")
    func notStartedHasDescription() {
        #expect(!HotkeyManager.ManagerError.notStarted.description.isEmpty)
    }
}
