import CoreGraphics
import Testing

@testable import CometDecoration

/// 枠線を出してよいかの判定。
///
/// **Mission Control・別 Space のネイティブ全画面・Cmd+H で枠線が残る**という
/// 報告から入れた判定。いずれも AX 上のウィンドウは生きたまま同じ矩形を返すので、
/// 画面に出ているウィンドウの一覧と突き合わせるしか見分ける方法が無い
///（`NSWorkspace` にも AX にも Mission Control の通知は来ないことを実測）。
@Suite("枠線を出してよいか")
struct WindowVisibilityTests {

    private func screen(
        onScreen: Set<CGWindowID>, overlay: Bool = false
    ) -> WindowVisibility.Screen {
        WindowVisibility.Screen(onScreen: onScreen, systemOverlayIsVisible: overlay)
    }

    @Test("画面に出ていれば出す")
    func showsWhenOnScreen() {
        #expect(WindowVisibility.shouldShowBorder(for: 42, screen: screen(onScreen: [1, 42, 7])))
    }

    /// Cmd+H・最小化・別 Space（他アプリのネイティブ全画面）では一覧から消える（実測）。
    @Test("画面から消えていれば出さない")
    func hidesWhenOffScreen() {
        #expect(!WindowVisibility.shouldShowBorder(for: 42, screen: screen(onScreen: [1, 7])))
        #expect(!WindowVisibility.shouldShowBorder(for: 42, screen: screen(onScreen: [])))
    }

    /// **Mission Control は一覧から消えない。** ウィンドウは縮小して並ぶだけで
    /// 一覧には残るため、ID の有無だけを見ていると枠線が残る（実測でそう出た）。
    @Test("Mission Control 中は一覧に残っていても出さない")
    func hidesWhileSystemOverlayIsVisible() {
        #expect(
            !WindowVisibility.shouldShowBorder(
                for: 42, screen: screen(onScreen: [1, 42, 7], overlay: true)))
    }

    /// **失敗を「1枚も出ていない」と扱わない。**
    /// そう扱うと、一覧が一度でも取れなかったときに枠線が消えたまま戻らない。
    @Test("一覧を取れないときは出す")
    func showsWhenUnknown() {
        #expect(WindowVisibility.shouldShowBorder(for: 42, screen: nil))
    }

    /// ID を渡さない呼び出し（dry-run など）では従来どおり出す。
    @Test("対象の ID が無いときは出す")
    func showsWithoutID() {
        #expect(WindowVisibility.shouldShowBorder(for: nil, screen: screen(onScreen: [])))
        #expect(WindowVisibility.shouldShowBorder(for: nil, screen: nil))
    }

    // MARK: - 一覧の読み取り

    private func window(
        id: CGWindowID, owner: String, size: CGSize
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: [
                "X": 0.0, "Y": 0.0, "Width": Double(size.width), "Height": Double(size.height),
            ],
        ]
    }

    @Test("Dock が画面全体を覆っていれば Mission Control とみなす")
    func detectsSystemOverlay() {
        let display = CGSize(width: 2560, height: 1664)
        let list = [
            window(id: 1, owner: "Dock", size: display),
            window(id: 2, owner: "WezTerm", size: CGSize(width: 1275, height: 799)),
        ]
        let parsed = WindowVisibility.parse(list, displaySizes: [display])
        #expect(parsed.systemOverlayIsVisible)
        #expect(parsed.onScreen == [1, 2])
    }

    /// **Dock 本体（帯）と取り違えてはいけない。** 取り違えると枠線が常に消える。
    @Test("Dock 本体は覆いとみなさない")
    func dockItselfIsNotAnOverlay() {
        let display = CGSize(width: 2560, height: 1664)
        let list = [
            window(id: 1, owner: "Dock", size: CGSize(width: 800, height: 90)),
            window(id: 2, owner: "WezTerm", size: CGSize(width: 1275, height: 799)),
        ]
        #expect(!WindowVisibility.parse(list, displaySizes: [display]).systemOverlayIsVisible)
    }
}
