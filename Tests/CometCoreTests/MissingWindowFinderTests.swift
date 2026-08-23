import CoreGraphics
import Darwin
import Testing

@testable import CometCore

/// AX の生成通知を取りこぼしたウィンドウの拾い直し。
///
/// **生成通知は当てにできない。** 生まれた直後の AX 要素はウィンドウ ID も属性も
/// 返さないことがあり（ブラウザや Electron 製アプリで起きる）、そこで諦めると
/// そのウィンドウには個別通知も張られないので、以後どの経路からも拾えない。
/// `CGWindowList` 側から「監視しているのに台帳に無い」窓を探す。
@Suite("取りこぼしたウィンドウの拾い直し")
struct MissingWindowFinderTests {

    private let own: pid_t = 999

    private func entry(
        pid: pid_t, layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600)
    ) -> ScreenWindows.Entry {
        ScreenWindows.Entry(
            layer: layer, bounds: CGRect(origin: .zero, size: size), ownerPID: pid)
    }

    private func owners(
        _ finder: inout MissingWindowFinder,
        _ screen: [CGWindowID: ScreenWindows.Entry],
        known: Set<CGWindowID> = [],
        monitored: Set<pid_t> = [10, 20]
    ) -> [pid_t] {
        finder.owners(
            screen: screen, known: { known.contains($0) }, monitored: { monitored.contains($0) },
            own: own)
    }

    @Test("台帳に無いウィンドウの持ち主を走査し直す")
    func findsTheOwnerOfAnUnknownWindow() {
        var finder = MissingWindowFinder()
        #expect(owners(&finder, [1: entry(pid: 10)]) == [10])
    }

    @Test("台帳にあるウィンドウは対象にしない")
    func knownWindowsAreIgnored() {
        var finder = MissingWindowFinder()
        #expect(owners(&finder, [1: entry(pid: 10)], known: [1]).isEmpty)
    }

    /// **管理対象外のウィンドウも台帳には載る。** 載っているものを「知らない」と
    /// 扱うと、ダイアログを開いている間ずっと走査し直すことになる。
    @Test("監視していないアプリは走査できない")
    func unmonitoredApplicationsAreSkipped() {
        var finder = MissingWindowFinder()
        #expect(owners(&finder, [1: entry(pid: 77)]).isEmpty)
    }

    @Test("自分のウィンドウ（枠線や HUD）は対象にしない")
    func ownWindowsAreSkipped() {
        var finder = MissingWindowFinder()
        #expect(owners(&finder, [1: entry(pid: own)], monitored: [own]).isEmpty)
    }

    /// ピクチャーインピクチャや常時最前面のパネルは並べる対象ではない。
    @Test("通常の階層でないウィンドウは対象にしない")
    func nonNormalLayersAreSkipped() {
        var finder = MissingWindowFinder()
        #expect(owners(&finder, [1: entry(pid: 10, layer: 3)]).isEmpty)
    }

    @Test("小さすぎるウィンドウは対象にしない")
    func tinyWindowsAreSkipped() {
        var finder = MissingWindowFinder()
        let tiny = entry(pid: 10, size: CGSize(width: 20, height: 20))
        #expect(owners(&finder, [1: tiny]).isEmpty)
    }

    /// 走査しても拾えない窓（ID を取れない疑似ウィンドウなど）と延々付き合わない。
    @Test("何度走査しても拾えないなら数えるのをやめる")
    func givesUpAfterRepeatedFailures() {
        var finder = MissingWindowFinder(maxAttempts: 3)
        let screen = [CGWindowID(1): entry(pid: 10)]
        for _ in 0..<3 {
            #expect(owners(&finder, screen) == [10])
        }
        #expect(owners(&finder, screen).isEmpty)
        #expect(finder.abandonedCount == 1)
    }

    /// 画面から消えたら記録を捨てる。**同じ ID は別のウィンドウに振られる。**
    @Test("画面から消えたら数え直す")
    func aVanishedWindowIsForgotten() {
        var finder = MissingWindowFinder(maxAttempts: 2)
        let screen = [CGWindowID(1): entry(pid: 10)]
        _ = owners(&finder, screen)
        _ = owners(&finder, screen)
        #expect(owners(&finder, screen).isEmpty)

        _ = owners(&finder, [:])
        #expect(owners(&finder, screen) == [10])
    }

    @Test("台帳に載ったら記録を捨てる")
    func anAdoptedWindowIsForgotten() {
        var finder = MissingWindowFinder(maxAttempts: 2)
        let screen = [CGWindowID(1): entry(pid: 10)]
        _ = owners(&finder, screen)
        _ = owners(&finder, screen, known: [1])
        #expect(finder.abandonedCount == 0)
    }

    /// 副作用（走査の発行）の順序を実行ごとにぶれさせない。
    @Test("持ち主は昇順で返す")
    func ownersAreSorted() {
        var finder = MissingWindowFinder()
        let screen = [
            CGWindowID(5): entry(pid: 20),
            CGWindowID(1): entry(pid: 10),
            CGWindowID(9): entry(pid: 20),
        ]
        #expect(owners(&finder, screen) == [10, 20])
    }
}
