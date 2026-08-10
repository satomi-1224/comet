import Darwin
import Testing

@testable import CometSupport

/// AX 適用のレイテンシをアプリ別に集計する。
///
/// **「どのアプリが足を引っ張っているか」が即座に分かる**ことが目的。
/// 症状が再発したときの調査コストが桁で変わる（設計書 §11.3）。
@Suite("TimingRecorder")
struct TimingRecorderTests {

    // MARK: - 有効・無効

    // 常時動く WM なので、無効のときは記録も割り当ても起きないこと。
    @Test("無効なら何も記録しない")
    func disabledRecordsNothing() {
        let recorder = TimingRecorder(isEnabled: false)
        recorder.record("setPosition", pid: 1, seconds: 0.01)
        #expect(recorder.summaries().isEmpty)
    }

    @Test("無効でも measure は本体を実行して値を返す")
    func disabledStillRuns() {
        let recorder = TimingRecorder(isEnabled: false)
        var ran = false
        let result = recorder.measure("setPosition", pid: 1) {
            ran = true
            return 42
        }
        #expect(ran)
        #expect(result == 42)
        #expect(recorder.summaries().isEmpty)
    }

    @Test("有効なら measure が記録する")
    func enabledMeasureRecords() {
        let recorder = TimingRecorder(isEnabled: true)
        _ = recorder.measure("setPosition", pid: 7) { 1 }
        let summaries = recorder.summaries()

        #expect(summaries.count == 1)
        #expect(summaries.first?.operation == "setPosition")
        #expect(summaries.first?.pid == 7)
        #expect(summaries.first?.count == 1)
    }

    // MARK: - 集計

    @Test("秒をミリ秒に換算する")
    func convertsToMilliseconds() {
        let recorder = TimingRecorder(isEnabled: true)
        recorder.record("setSize", pid: 1, seconds: 0.0123)
        #expect(abs((recorder.summaries().first?.p50 ?? 0) - 12.3) < 1e-6)
    }

    @Test("1件なら全ての分位が同じ値")
    func singleSampleHasIdenticalPercentiles() {
        let recorder = TimingRecorder(isEnabled: true)
        recorder.record("setSize", pid: 1, seconds: 0.005)
        let summary = recorder.summaries().first

        #expect(summary?.p50 == 5)
        #expect(summary?.p95 == 5)
        #expect(summary?.p99 == 5)
        #expect(summary?.maximum == 5)
    }

    @Test("100件の分位を求められる")
    func percentilesOverHundredSamples() throws {
        let recorder = TimingRecorder(isEnabled: true)
        // 1ms, 2ms, ... 100ms を投入順を混ぜて入れる。並べ替えは集計側の責任。
        for value in [Int](1...100).shuffledDeterministically() {
            recorder.record("setPosition", pid: 1, seconds: Double(value) / 1000)
        }
        let summary = try #require(recorder.summaries().first)

        #expect(summary.count == 100)
        #expect(summary.p50 == 50)
        #expect(summary.p95 == 95)
        #expect(summary.p99 == 99)
        #expect(summary.maximum == 100)
    }

    @Test("操作と PID の組ごとに分かれる")
    func splitsByOperationAndPID() {
        let recorder = TimingRecorder(isEnabled: true)
        recorder.record("setPosition", pid: 1, seconds: 0.001)
        recorder.record("setPosition", pid: 2, seconds: 0.002)
        recorder.record("setSize", pid: 1, seconds: 0.003)

        #expect(recorder.summaries().count == 3)
    }

    @Test("件数の多い順に並ぶ")
    func sortedByCount() {
        let recorder = TimingRecorder(isEnabled: true)
        recorder.record("rare", pid: 1, seconds: 0.001)
        for _ in 0..<5 {
            recorder.record("common", pid: 1, seconds: 0.001)
        }
        #expect(recorder.summaries().map(\.operation) == ["common", "rare"])
    }

    // 何日も動き続けるプロセスなので、標本を無制限に持つとメモリが増え続ける。
    @Test("標本は上限で打ち切られ、新しいものが残る")
    func samplesAreCapped() throws {
        let recorder = TimingRecorder(isEnabled: true, capacity: 4)
        for value in 1...10 {
            recorder.record("setPosition", pid: 1, seconds: Double(value) / 1000)
        }
        let summary = try #require(recorder.summaries().first)

        #expect(summary.count == 4, "保持しているのは上限まで")
        #expect(summary.observed == 10, "受け取った総数は数え続ける")
        #expect(summary.maximum == 10, "残っているのは新しい 7〜10ms")
        // 最近順位法なので [7,8,9,10] の p50 は2番目に小さい 8。
        #expect(summary.p50 == 8)
    }

    @Test("reset で消える")
    func resetClears() {
        let recorder = TimingRecorder(isEnabled: true)
        recorder.record("setPosition", pid: 1, seconds: 0.001)
        recorder.reset()
        #expect(recorder.summaries().isEmpty)
    }

    // MARK: - 出力

    @Test("行に整形できる")
    func rendersLines() {
        let recorder = TimingRecorder(isEnabled: true)
        recorder.record("setPosition", pid: 42, seconds: 0.003)
        let lines = recorder.report { pid in pid == 42 ? "WezTerm" : nil }

        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.contains("setPosition"))
        #expect(line.contains("pid=42"))
        #expect(line.contains("WezTerm"))
        #expect(line.contains("p50="))
        #expect(line.contains("n=1"))
    }

    @Test("アプリ名が分からなくても行にできる")
    func rendersWithoutAppName() {
        let recorder = TimingRecorder(isEnabled: true)
        recorder.record("setSize", pid: 42, seconds: 0.003)
        #expect(recorder.report { _ in nil }.count == 1)
    }

    @Test("何も記録されていなければ行は出ない")
    func rendersNothingWhenEmpty() {
        #expect(TimingRecorder(isEnabled: true).report { _ in nil }.isEmpty)
    }
}

extension Array where Element == Int {
    /// テストを決定的にするための、乱数を使わない並べ替え。
    fileprivate func shuffledDeterministically() -> [Int] {
        // 奇数を先に、偶数を後ろに。順序が集計へ影響しないことを確かめるだけなので
        // 「入力順とソート順が違う」ことだけ満たせばよい。
        filter { $0 % 2 == 1 }.reversed() + filter { $0 % 2 == 0 }
    }
}
