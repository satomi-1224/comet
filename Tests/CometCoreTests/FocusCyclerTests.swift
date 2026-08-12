import CoreGraphics
import Testing

@testable import CometCore

/// アプリ巡回（`focus next-app`）とアプリ内のウィンドウ巡回（`focus next-window-in-app`）。
///
/// Hammerspoon の `Alt+F` / `Alt+D` を comet 側へ移したもの。
/// 二重にウィンドウ一覧を持たなくなる。
///
/// **要点は「押し続けている間は並びを組み直さない」こと。** フォーカスすると
/// 最近使った順が変わるので、毎回組み直すと2つのアプリの間を往復するだけになる。
@Suite("FocusCycler")
struct FocusCyclerTests {

    /// pid 100 が2枚、200 が1枚、300 が1枚。数字が大きいほど最近使った。
    private let candidates: [FocusCycler.Candidate] = [
        .init(id: 11, pid: 100, lastFocusedAt: 40),
        .init(id: 12, pid: 100, lastFocusedAt: 10),
        .init(id: 21, pid: 200, lastFocusedAt: 30),
        .init(id: 31, pid: 300, lastFocusedAt: 20),
    ]

    // MARK: - アプリの並び

    /// 最近使った順。各アプリの代表は**そのアプリで最後に使ったウィンドウ**。
    @Test("アプリは最近使った順に並び、代表は直近のウィンドウ")
    func appOrderIsMostRecentlyUsed() {
        #expect(FocusCycler.appOrder(candidates) == [11, 21, 31])
    }

    @Test("同じアプリのウィンドウは1つしか並びに入らない")
    func oneWindowPerApp() {
        let order = FocusCycler.appOrder(candidates)
        #expect(order.count == 3, "pid は 3 種類")
        #expect(!order.contains(12), "pid 100 の代表は 11 だけ")
    }

    @Test("候補が1つなら並びも1つ")
    func singleCandidate() {
        #expect(FocusCycler.appOrder([.init(id: 1, pid: 1, lastFocusedAt: 0)]) == [1])
    }

    @Test("候補が無ければ空")
    func noCandidates() {
        #expect(FocusCycler.appOrder([]).isEmpty)
    }

    /// 一度もフォーカスしていないウィンドウ（`lastFocusedAt` が 0）も並びに入る。
    /// 起動直後に巡回できないと使い物にならない。
    @Test("まだフォーカスしていないウィンドウも並びに入る")
    func neverFocusedWindowsAreIncluded() {
        let fresh: [FocusCycler.Candidate] = [
            .init(id: 1, pid: 1, lastFocusedAt: 0),
            .init(id: 2, pid: 2, lastFocusedAt: 0),
        ]
        #expect(FocusCycler.appOrder(fresh).count == 2)
    }

    // MARK: - アプリ内のウィンドウの並び

    /// **こちらは最近使った順にしない。** 最近使った順だと2枚の間を往復するだけで、
    /// 3枚以上あるときに残りへ行けない。id の昇順という固定の輪にする。
    @Test("アプリ内は id の昇順で固定の輪になる")
    func windowsInAppUseStableOrder() {
        #expect(FocusCycler.windowsInApp(candidates, pid: 100) == [11, 12])
        #expect(FocusCycler.windowsInApp(candidates, pid: 200) == [21])
        #expect(FocusCycler.windowsInApp(candidates, pid: 999).isEmpty)
    }

    // MARK: - 巡回

    @Test("次へ進む")
    func advancesForward() {
        #expect(FocusCycler.next(in: [1, 2, 3], from: 1, forward: true) == 2)
        #expect(FocusCycler.next(in: [1, 2, 3], from: 2, forward: true) == 3)
    }

    @Test("末尾から先頭へ回る")
    func wrapsAround() {
        #expect(FocusCycler.next(in: [1, 2, 3], from: 3, forward: true) == 1)
        #expect(FocusCycler.next(in: [1, 2, 3], from: 1, forward: false) == 3)
    }

    @Test("前へ戻る")
    func advancesBackward() {
        #expect(FocusCycler.next(in: [1, 2, 3], from: 3, forward: false) == 2)
    }

    /// 今いるウィンドウが並びに無い場合（別のワークスペースへ移った直後など）は先頭へ。
    @Test("今の位置が分からなければ先頭へ")
    func unknownCurrentGoesToFirst() {
        #expect(FocusCycler.next(in: [1, 2, 3], from: 99, forward: true) == 1)
        #expect(FocusCycler.next(in: [1, 2, 3], from: nil, forward: true) == 1)
    }

    @Test("1つしか無ければ動かない")
    func singleElementStaysPut() {
        #expect(FocusCycler.next(in: [7], from: 7, forward: true) == nil)
    }

    @Test("空の並びでは何も選べない")
    func emptyOrder() {
        #expect(FocusCycler.next(in: [], from: 1, forward: true) == nil)
    }

    // MARK: - 巡回の続き（セッション）

    /// **押し続けている間は並びを組み直さない。** 組み直すと、フォーカスした結果
    /// 最近使った順が変わり、2つのアプリの間を往復するだけになる。
    @Test("続けて押すと同じ並びを順に辿る")
    func sessionWalksTheSameOrder() {
        var session = FocusCycler.Session()
        // 1回目: 並びを組んで次（2番目）へ
        let first = session.advance(
            order: [11, 21, 31], now: 0, resetAfter: 1.5, forward: true)
        #expect(first == 21)
        // 2回目: 組み直さず3番目へ
        let second = session.advance(
            order: [21, 11, 31], now: 0.2, resetAfter: 1.5, forward: true)
        #expect(second == 31, "並びが変わっても続きを辿る")
        // 3回目: 先頭へ回る
        let third = session.advance(
            order: [31, 21, 11], now: 0.4, resetAfter: 1.5, forward: true)
        #expect(third == 11)
    }

    @Test("時間が経つと最近使った順で組み直す")
    func sessionExpires() {
        var session = FocusCycler.Session()
        #expect(session.advance(order: [11, 21, 31], now: 0, resetAfter: 1.5, forward: true) == 21)
        // 1.5 秒を過ぎたので、渡された新しい並びの2番目から始まる
        #expect(session.advance(order: [21, 11, 31], now: 2.0, resetAfter: 1.5, forward: true) == 11)
    }

    @Test("リセット時間が 0 なら毎回組み直す")
    func zeroResetRebuildsEveryTime() {
        var session = FocusCycler.Session()
        #expect(session.advance(order: [11, 21], now: 0, resetAfter: 0, forward: true) == 21)
        #expect(session.advance(order: [21, 11], now: 0.01, resetAfter: 0, forward: true) == 11)
    }

    /// 巡回中に閉じたウィンドウを掴んだままだと、消えたウィンドウへフォーカスしようとする。
    @Test("並びから消えたウィンドウがあれば組み直す")
    func rebuildsWhenWindowDisappears() {
        var session = FocusCycler.Session()
        #expect(session.advance(order: [11, 21, 31], now: 0, resetAfter: 1.5, forward: true) == 21)
        // 21 が閉じられた。残りで組み直す。
        #expect(session.advance(order: [11, 31], now: 0.2, resetAfter: 1.5, forward: true) == 31)
    }

    @Test("逆順にも巡回できる")
    func sessionBackward() {
        var session = FocusCycler.Session()
        #expect(session.advance(order: [11, 21, 31], now: 0, resetAfter: 1.5, forward: false) == 31)
        #expect(session.advance(order: [11, 21, 31], now: 0.2, resetAfter: 1.5, forward: false) == 21)
    }

    // MARK: - コマンドの綴り

    @Test("設定に書ける綴り")
    func parsesCommands() throws {
        #expect(try Command.parse("focus next-app") == .focusCycle(.nextApp))
        #expect(try Command.parse("focus prev-app") == .focusCycle(.previousApp))
        #expect(try Command.parse("focus next-window-in-app") == .focusCycle(.nextWindowInApp))
        #expect(try Command.parse("focus prev-window-in-app") == .focusCycle(.previousWindowInApp))
        // 方向は今までどおり
        #expect(try Command.parse("focus left") == .focus(.left))
    }

    @Test("綴りに戻せる")
    func roundTrip() throws {
        for command in [
            Command.focusCycle(.nextApp), .focusCycle(.previousApp),
            .focusCycle(.nextWindowInApp), .focusCycle(.previousWindowInApp),
        ] {
            #expect(try Command.parse(command.description) == command)
        }
    }

    @Test("知らない引数は方向として解釈できないと分かる")
    func unknownArgument() {
        #expect(throws: Command.ParseError.invalidArgument(name: "focus", argument: "sideways")) {
            try Command.parse("focus sideways")
        }
    }
}
