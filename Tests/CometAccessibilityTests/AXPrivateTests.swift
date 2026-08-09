import ApplicationServices
import Testing

@testable import CometAccessibility

@Suite("AXPrivate")
struct AXPrivateTests {

    // これは実装ではなく実行環境に対する検査。
    // OS アップデートで _AXUIElementGetWindow が消えた場合、
    // このテストが落ちることで即座に気づける（設計書 §12.2 のカナリア）。
    @Test("_AXUIElementGetWindow が解決できる")
    func symbolResolves() {
        #expect(
            AXPrivate.isGetWindowAvailable,
            """
            _AXUIElementGetWindow を解決できなかった。
            OS アップデートでシンボルが削除された可能性がある。
            設計書 §12.2 のフォールバック（CGWindowListCopyWindowInfo からの推定）が必要。
            """)
    }

    @Test("解決結果はキャッシュされ、何度呼んでも同じ")
    func resolutionIsStable() {
        let first = AXPrivate.isGetWindowAvailable
        for _ in 0..<100 {
            #expect(AXPrivate.isGetWindowAvailable == first)
        }
    }

    // 無効な要素を渡しても落ちないこと。AX 要素はアプリ終了で常時無効化されるため、
    // 無効要素の扱いは例外ではなく通常経路。
    @Test("到達不能なプロセスの要素では nil を返す")
    func returnsNilForUnreachableProcess() {
        // 存在しない PID からアプリ要素を作る。AXUIElementCreateApplication 自体は
        // 検証を行わないので要素は得られるが、問い合わせは失敗する。
        let element = AXUIElementCreateApplication(pid_t.max)
        #expect(AXPrivate.windowID(of: element) == nil)
    }

    @Test("アプリ要素はウィンドウではないので nil を返す")
    func returnsNilForApplicationElement() {
        // 自プロセスのアプリ要素。生きているがウィンドウ ID は持たない。
        let element = AXUIElementCreateApplication(getpid())
        #expect(AXPrivate.windowID(of: element) == nil)
    }
}
