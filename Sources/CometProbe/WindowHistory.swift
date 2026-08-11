/// ある時刻に観測したウィンドウの矩形。
public struct WindowSample: Equatable, Sendable {
    /// 観測を始めてからの経過（ms）。
    public let elapsedMs: Int
    public let rect: IntRect

    public init(elapsedMs: Int, rect: IntRect) {
        self.elapsedMs = elapsedMs
        self.rect = rect
    }
}

/// ウィンドウが落ち着くまでの様子。
public struct WindowSettleSummary: Equatable, Sendable {
    /// 最初に観測した位置。
    public let firstRect: IntRect
    /// 最後に観測した位置。これを「落ち着いた先」とみなす。
    public let finalRect: IntRect
    /// 観測した異なる位置の数。
    public let distinctPositions: Int
    /// **落ち着いた先とは違う場所に居た時間の合計。** 症状A の実体はこれ。
    public let msAtOtherPositions: Int
    /// 最後に落ち着いた先へ到達するまでの時間。
    public let msToSettle: Int

    public var didMove: Bool { distinctPositions > 1 }
}

/// ウィンドウの矩形の追跡結果をまとめる。
///
/// 症状A（新規ウィンドウがデフォルト位置に一瞬出てから飛ぶ）は
/// 「目視でしか判定できない」と考えていたが、**ちらつきの実体は
/// 「最終的に落ち着く位置とは違う場所に、画面上に居た時間」**である。
/// 矩形を細かく追えば数値になる。
public enum WindowHistory {

    public static func summarize(_ samples: [WindowSample], tolerance: Int) -> WindowSettleSummary? {
        guard !samples.isEmpty else { return nil }
        // 追跡側の都合で順序が乱れても答えが変わらないようにする。
        let ordered = samples.sorted { $0.elapsedMs < $1.elapsedMs }
        let final = ordered[ordered.count - 1].rect
        let start = ordered[0].elapsedMs

        // **最後に**落ち着いた先へ入った時点を探す。途中で一度そこへ来ただけの
        // 観測で判定すると、行って戻ってを繰り返した場合に「速い」と誤って報告する。
        var settleIndex = ordered.count - 1
        while settleIndex > 0, ordered[settleIndex - 1].rect.isNear(final, tolerance: tolerance) {
            settleIndex -= 1
        }

        // 落ち着いた先以外に居た時間。次の観測までを滞在時間とみなす。
        var msAtOthers = 0
        for index in ordered.indices where !ordered[index].rect.isNear(final, tolerance: tolerance) {
            let next = index + 1 < ordered.count ? ordered[index + 1].elapsedMs : ordered[index].elapsedMs
            msAtOthers += next - ordered[index].elapsedMs
        }

        var representatives: [IntRect] = []
        for sample in ordered
        where !representatives.contains(where: { $0.isNear(sample.rect, tolerance: tolerance) }) {
            representatives.append(sample.rect)
        }

        return WindowSettleSummary(
            firstRect: ordered[0].rect,
            finalRect: final,
            distinctPositions: representatives.count,
            msAtOtherPositions: msAtOthers,
            msToSettle: ordered[settleIndex].elapsedMs - start)
    }
}
