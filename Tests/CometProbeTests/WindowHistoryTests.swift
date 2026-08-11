import Testing

@testable import CometProbe

/// 症状A（新規ウィンドウがデフォルト位置に一瞬出てから飛ぶ）を数値にするための計算。
///
/// 「ちらついたか」は目で見るしかないと考えていたが、**ちらつきの実体は
/// 「最終的に落ち着く位置とは違う場所に、画面上に居た時間」**なので、
/// ウィンドウの矩形を細かく追えば数値になる。
///
/// 0ms なら現れた瞬間から目標位置に居たことになり、症状A は起きていない。
@Suite("WindowHistory")
struct WindowHistoryTests {

    private let defaultPosition = IntRect(x: 700, y: 400, width: 800, height: 600)
    private let tiled = IntRect(x: 5, y: 61, width: 1273, height: 1597)

    private func samples(_ pairs: [(Int, IntRect)]) -> [WindowSample] {
        pairs.map { WindowSample(elapsedMs: $0.0, rect: $0.1) }
    }

    @Test("観測が無ければ要約できない")
    func empty() {
        #expect(WindowHistory.summarize([], tolerance: 0) == nil)
    }

    /// 理想の姿。現れた瞬間から目標位置に居れば、ちらつく余地が無い。
    @Test("動かなければ他の位置に居た時間は 0")
    func neverMoved() {
        let history = samples([(0, tiled), (10, tiled), (20, tiled)])
        let summary = WindowHistory.summarize(history, tolerance: 0)
        #expect(summary?.didMove == false)
        #expect(summary?.msAtOtherPositions == 0)
        #expect(summary?.msToSettle == 0)
        #expect(summary?.distinctPositions == 1)
        #expect(summary?.firstRect == tiled)
        #expect(summary?.finalRect == tiled)
    }

    @Test("一度だけ動いたら、動く前に居た時間がそのまま出る")
    func movedOnce() {
        var pairs: [(Int, IntRect)] = []
        for t in stride(from: 0, through: 110, by: 10) { pairs.append((t, defaultPosition)) }
        for t in stride(from: 120, through: 200, by: 10) { pairs.append((t, tiled)) }
        let summary = WindowHistory.summarize(samples(pairs), tolerance: 0)
        #expect(summary?.didMove == true)
        #expect(summary?.msToSettle == 120)
        #expect(summary?.msAtOtherPositions == 120)
        #expect(summary?.distinctPositions == 2)
        #expect(summary?.firstRect == defaultPosition)
        #expect(summary?.finalRect == tiled)
    }

    /// 行ったり戻ったりするのが最も見苦しい壊れ方。**最後に落ち着いた時刻**で
    /// 判定しないと、途中で一度目標に来たことで「速い」と誤って報告してしまう。
    @Test("行って戻ってを繰り返したら、最後に落ち着いた時刻で判定する")
    func bouncedBack() {
        let history = samples([
            (0, defaultPosition), (50, defaultPosition),
            (60, tiled), (70, tiled),
            (80, defaultPosition), (90, defaultPosition),
            (100, tiled), (150, tiled),
        ])
        let summary = WindowHistory.summarize(history, tolerance: 0)
        #expect(summary?.msToSettle == 100)
        // 既定位置に居たのは 0〜60 と 80〜100 で合計 80ms。
        // 途中で目標位置に居た 60〜80 は「他の位置」ではないので数えない。
        #expect(summary?.msAtOtherPositions == 80)
        #expect(summary?.distinctPositions == 2)
    }

    /// 着地したあとも 1pt 単位で揺れることがある（アプリ側の最小サイズや
    /// 整数丸め）。厳密一致で数えると、その揺れが「ちらつき」に見えてしまう。
    @Test("許容差の内側の揺れは同じ位置とみなす")
    func jitterWithinTolerance() {
        let nudged = IntRect(x: tiled.x + 1, y: tiled.y, width: tiled.width - 1, height: tiled.height)
        let history = samples([(0, defaultPosition), (10, tiled), (20, nudged)])
        let summary = WindowHistory.summarize(history, tolerance: 2)
        #expect(summary?.msToSettle == 10)
        #expect(summary?.msAtOtherPositions == 10)
        #expect(summary?.distinctPositions == 2)
    }

    @Test("観測の順序が乱れていても時刻で並べ直す")
    func unorderedSamples() {
        let history = samples([(120, tiled), (0, defaultPosition), (60, defaultPosition)])
        let summary = WindowHistory.summarize(history, tolerance: 0)
        #expect(summary?.firstRect == defaultPosition)
        #expect(summary?.msToSettle == 120)
    }

    // MARK: - 矩形の近さ

    @Test("許容差は各辺に対して見る")
    func rectProximity() {
        let base = IntRect(x: 100, y: 100, width: 200, height: 200)
        #expect(base.isNear(IntRect(x: 102, y: 100, width: 200, height: 200), tolerance: 2))
        #expect(!base.isNear(IntRect(x: 103, y: 100, width: 200, height: 200), tolerance: 2))
        // 位置が同じでも大きさが違えば別の位置。リサイズを見逃さないため。
        #expect(!base.isNear(IntRect(x: 100, y: 100, width: 210, height: 200), tolerance: 2))
    }
}
