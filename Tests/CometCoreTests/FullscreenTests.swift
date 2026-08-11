import CoreGraphics
import Testing

@testable import CometCore

/// 1枚をモニタいっぱいに広げる（設計書 §9.2 の `fullscreen`）。
///
/// **macOS のネイティブフルスクリーンは使わない。** あれは専用の操作スペースを作るため、
/// ワークスペースの実装（アプリごと非表示）と衝突する（README の前提条件）。
/// ここでやるのは「タイル配置の中で1枚だけ領域いっぱいにする」トグル。
@Suite("fullscreen")
struct FullscreenTests {

    private let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let gaps = Gaps(
        innerHorizontal: 10, innerVertical: 10, outerTop: 20, outerBottom: 20, outerLeft: 20,
        outerRight: 20)

    private func tree(_ ids: [CGWindowID]) -> ContainerNode {
        let root = ContainerNode(orientation: .horizontal)
        for id in ids { root.append(WindowNode(id)) }
        return root
    }

    @Test("指定したウィンドウが外側ギャップだけを残して広がる")
    func fillsUsableArea() {
        let layout = LayoutEngine.compute(
            root: tree([1, 2, 3]), area: area, gaps: gaps, scale: 1, fullscreen: 2)
        // 外側ギャップ 20 を四方に残した領域。
        #expect(layout.frames[2] == CGRect(x: 20, y: 20, width: 960, height: 760))
    }

    /// 全画面のウィンドウは他を覆うだけで、**後ろのウィンドウの配置は変えない。**
    /// 解除したときに元の位置へ戻す計算をやり直さずに済む。
    @Test("他のウィンドウの矩形は変わらない")
    func othersKeepTheirFrames() {
        let normal = LayoutEngine.compute(root: tree([1, 2, 3]), area: area, gaps: gaps, scale: 1)
        let full = LayoutEngine.compute(
            root: tree([1, 2, 3]), area: area, gaps: gaps, scale: 1, fullscreen: 2)
        #expect(full.frames[1] == normal.frames[1])
        #expect(full.frames[3] == normal.frames[3])
        #expect(full.order == normal.order)
    }

    @Test("指定しなければ通常のレイアウトと同じ")
    func noFullscreen() {
        let normal = LayoutEngine.compute(root: tree([1, 2]), area: area, gaps: gaps, scale: 1)
        let explicit = LayoutEngine.compute(
            root: tree([1, 2]), area: area, gaps: gaps, scale: 1, fullscreen: nil)
        #expect(explicit.frames == normal.frames)
    }

    /// ワークスペースを移った・閉じたウィンドウの id が残っていても、
    /// レイアウトが壊れてはいけない。
    @Test("ツリーに無いウィンドウを指定しても通常のレイアウトになる")
    func unknownWindowIsIgnored() {
        let normal = LayoutEngine.compute(root: tree([1, 2]), area: area, gaps: gaps, scale: 1)
        let stale = LayoutEngine.compute(
            root: tree([1, 2]), area: area, gaps: gaps, scale: 1, fullscreen: 99)
        #expect(stale.frames == normal.frames)
    }

    @Test("1枚だけのときも領域いっぱいになる")
    func singleWindow() {
        let layout = LayoutEngine.compute(
            root: tree([7]), area: area, gaps: gaps, scale: 1, fullscreen: 7)
        #expect(layout.frames[7] == CGRect(x: 20, y: 20, width: 960, height: 760))
    }

    // MARK: - コマンドの綴り

    @Test("設定に fullscreen と書ける")
    func parsesCommand() throws {
        #expect(try Command.parse("fullscreen") == .fullscreen)
        #expect(Command.fullscreen.description == "fullscreen")
    }

    @Test("引数は取らない")
    func rejectsArguments() {
        #expect(throws: Command.ParseError.wrongArgumentCount(name: "fullscreen", expected: "0", got: 1)) {
            try Command.parse("fullscreen next")
        }
    }
}
