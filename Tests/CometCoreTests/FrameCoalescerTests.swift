import CoreGraphics
import Testing

@testable import CometCore

/// 症状B（リサイズ連打で追従しない・飛ぶ・戻る）への対策そのもの。
///
/// 打鍵のたびに AX 呼び出しを発行するとキューが詰まり、キーを離した後も
/// 溜まった分が処理され続ける。合成器は「最新の目標だけを残し、中間状態を捨てる」
/// ことでこれを原理的に起こらなくする。
@Suite("FrameCoalescer")
struct FrameCoalescerTests {

    private func rect(_ width: CGFloat, _ height: CGFloat = 100) -> CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func target(_ width: CGFloat, setSize: Bool = true) -> TargetFrame {
        TargetFrame(rect: rect(width), setSize: setSize)
    }

    // MARK: - 基本

    @Test("生成直後は待機中")
    func startsIdle() {
        let coalescer = FrameCoalescer()
        #expect(coalescer.isIdle)
        #expect(coalescer.pendingCount == 0)
        #expect(coalescer.inFlightCount == 0)
    }

    @Test("submit した目標は drain で取り出せる")
    func submitThenDrain() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        #expect(!coalescer.isIdle)

        let requests = coalescer.drain()
        #expect(requests.count == 1)
        #expect(requests[0].windowID == 1)
        #expect(requests[0].target.rect.width == 100)
    }

    @Test("drain した時点で適用中になる")
    func drainMarksInFlight() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()

        #expect(coalescer.inFlightCount == 1)
        #expect(coalescer.pendingCount == 0)
        #expect(!coalescer.isIdle, "適用中は待機中ではない")
    }

    @Test("complete で適用中が解除され待機中に戻る")
    func completeClearsInFlight() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()
        coalescer.complete(1)

        #expect(coalescer.inFlightCount == 0)
        #expect(coalescer.isIdle)
    }

    // MARK: - 合成（症状Bの中核）

    @Test("drain 前の連続 submit は最新の1件に畳まれる")
    func multipleSubmitsCollapse() {
        var coalescer = FrameCoalescer()
        for step in 1...30 {
            coalescer.submit(1, target(CGFloat(step) * 10))
        }
        #expect(coalescer.pendingCount == 1, "同一ウィンドウは1件に畳まれる")

        let requests = coalescer.drain()
        #expect(requests.count == 1)
        #expect(requests[0].target.rect.width == 300, "最後の値だけが残る")
    }

    // キーリピートは 25〜30 回/秒。1打鍵あたり AX 呼び出しが複数回走るため、
    // 適用中に届いた分を全て発行するとキューが詰まって「離した後も動き続ける」。
    @Test("適用中に届いた連打は、完了後に最新値だけが発行される")
    func submitsDuringInFlightCollapse() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()

        for step in 2...20 {
            coalescer.submit(1, target(CGFloat(step) * 100))
        }

        #expect(coalescer.drain().isEmpty, "適用中は追加発行しない")

        coalescer.complete(1)
        let requests = coalescer.drain()
        #expect(requests.count == 1)
        #expect(requests[0].target.rect.width == 2000, "中間の18件は捨てられる")
    }

    @Test("適用中でも他のウィンドウは発行される")
    func inFlightDoesNotBlockOtherWindows() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()

        coalescer.submit(2, target(200))
        let requests = coalescer.drain()
        #expect(requests.map(\.windowID) == [2])
    }

    // MARK: - 無変化の抑制

    @Test("適用済みと同じ目標は発行しない")
    func unchangedTargetIsSkipped() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()
        coalescer.complete(1)

        coalescer.submit(1, target(100))
        #expect(coalescer.drain().isEmpty, "同じ矩形なら AX 呼び出しは不要")
        #expect(coalescer.isIdle)
    }

    @Test("許容誤差内のずれは同一とみなす")
    func withinToleranceIsSkipped() {
        var coalescer = FrameCoalescer(tolerance: 0.5)
        coalescer.submit(1, target(100))
        _ = coalescer.drain()
        coalescer.complete(1)

        coalescer.submit(1, target(100.2))
        #expect(coalescer.drain().isEmpty)
    }

    @Test("許容誤差を超えたら発行する")
    func beyondToleranceIsIssued() {
        var coalescer = FrameCoalescer(tolerance: 0.5)
        coalescer.submit(1, target(100))
        _ = coalescer.drain()
        coalescer.complete(1)

        coalescer.submit(1, target(101))
        #expect(coalescer.drain().count == 1)
    }

    // 位置だけ設定する要求（ワークスペース切替の最適化）と
    // サイズも設定する要求は別物なので、矩形が同じでも畳んではいけない。
    @Test("矩形が同じでも setSize が変われば発行する")
    func setSizeChangeIsIssued() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100, setSize: false))
        _ = coalescer.drain()
        coalescer.complete(1)

        coalescer.submit(1, target(100, setSize: true))
        let requests = coalescer.drain()
        #expect(requests.count == 1)
        #expect(requests[0].target.setSize)
    }

    // MARK: - 順序

    @Test("drain の順序は submit の順序を保つ")
    func drainPreservesSubmissionOrder() {
        var coalescer = FrameCoalescer()
        coalescer.submit(30, target(100))
        coalescer.submit(10, target(100))
        coalescer.submit(20, target(100))

        #expect(coalescer.drain().map(\.windowID) == [30, 10, 20])
    }

    @Test("再 submit は元の順序位置を保つ")
    func resubmitKeepsPosition() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        coalescer.submit(2, target(100))
        coalescer.submit(1, target(150))

        let requests = coalescer.drain()
        #expect(requests.map(\.windowID) == [1, 2])
        #expect(requests[0].target.rect.width == 150)
    }

    // MARK: - ウィンドウの消滅

    @Test("forget で全ての状態が消える")
    func forgetClearsAllState() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()
        coalescer.submit(1, target(200))

        coalescer.forget(1)

        #expect(coalescer.isIdle)
        #expect(coalescer.pendingCount == 0)
        #expect(coalescer.inFlightCount == 0)
        #expect(coalescer.appliedFrame(1) == nil)
        #expect(coalescer.drain().isEmpty)
    }

    // ウィンドウが閉じた後に適用完了が返ってくる競合。無視できなければならない。
    @Test("forget 済みウィンドウの complete は無害")
    func completeAfterForgetIsHarmless() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()
        coalescer.forget(1)
        coalescer.complete(1)
        #expect(coalescer.isIdle)
    }

    @Test("forget 後に同じ矩形を submit すると再び発行される")
    func forgetResetsAppliedFrame() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()
        coalescer.complete(1)
        coalescer.forget(1)

        coalescer.submit(1, target(100))
        #expect(coalescer.drain().count == 1, "適用履歴が消えているので再適用が必要")
    }

    // MARK: - 想定外の入力

    // アプリが目標どおりに動かなかったときの補正は、同じ矩形を投げ直すことになる。
    // 適用履歴が残っていると「変化なし」と判定されて発行されない。
    @Test("invalidate すると同じ目標でも再発行される")
    func invalidateAllowsResubmit() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()
        coalescer.complete(1)

        coalescer.submit(1, target(100))
        #expect(coalescer.drain().isEmpty, "履歴があるうちは発行しない")

        coalescer.invalidate(1)
        coalescer.submit(1, target(100))
        #expect(coalescer.drain().count == 1, "履歴を捨てれば発行される")
    }

    @Test("invalidate は待機中と適用中には触れない")
    func invalidateLeavesQueuesIntact() {
        var coalescer = FrameCoalescer()
        coalescer.submit(1, target(100))
        _ = coalescer.drain()

        coalescer.invalidate(1)
        #expect(coalescer.inFlightCount == 1, "適用中の状態は保つ")
        #expect(coalescer.appliedFrame(1) == nil, "履歴だけが消える")
    }

    @Test("知らないウィンドウの invalidate は無害")
    func invalidateUnknownIsHarmless() {
        var coalescer = FrameCoalescer()
        coalescer.invalidate(999)
        #expect(coalescer.isIdle)
    }

    @Test("知らないウィンドウの complete は無害")
    func completeUnknownIsHarmless() {
        var coalescer = FrameCoalescer()
        coalescer.complete(999)
        #expect(coalescer.isIdle)
    }

    @Test("何も無い状態の drain は空を返す")
    func drainWhenEmpty() {
        var coalescer = FrameCoalescer()
        #expect(coalescer.drain().isEmpty)
    }

    @Test("一括 submit も個別 submit と同じに扱われる")
    func batchSubmit() {
        var coalescer = FrameCoalescer()
        coalescer.submit([1: target(100), 2: target(200)], order: [1, 2])
        #expect(coalescer.drain().map(\.windowID) == [1, 2])
    }

    @Test("適用済み矩形を参照できる")
    func appliedFrameIsRecorded() {
        var coalescer = FrameCoalescer()
        #expect(coalescer.appliedFrame(1) == nil)

        coalescer.submit(1, target(100))
        #expect(coalescer.appliedFrame(1) == nil, "drain 前は未適用")

        _ = coalescer.drain()
        #expect(coalescer.appliedFrame(1) == rect(100), "発行した時点で記録される")
    }
}
