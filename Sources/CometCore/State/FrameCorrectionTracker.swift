import CoreGraphics

/// 目標へ追従しないウィンドウの補正を、必要な回数だけに絞る純粋な状態機械。
struct FrameCorrectionTracker {

    enum GiveUpReason: Equatable {
        /// 設定された補正回数を使い切った。
        case exhausted
        /// 同じ目標へ投げ直しても実測が全く変わらず、残りの再試行が無意味。
        case unchangedResult
    }

    enum Decision: Equatable {
        case settled
        case retry(Int)
        case giveUp(GiveUpReason)
    }

    private struct Attempt {
        var target: CGRect
        var observed: CGRect
        var retryCount: Int
    }

    private var attempts: [CGWindowID: Attempt] = [:]

    mutating func evaluate(
        _ id: CGWindowID,
        target: CGRect,
        observed: CGRect,
        tolerance: CGFloat,
        maxCorrections: Int
    ) -> Decision {
        guard !Geometry.isApproximatelyEqual(observed, target, tolerance: tolerance) else {
            attempts.removeValue(forKey: id)
            return .settled
        }

        var previous = attempts[id]
        if let existing = previous,
            !Geometry.isApproximatelyEqual(existing.target, target, tolerance: tolerance)
        {
            previous = nil
        }

        // 同じ目標へ一度投げ直しても実測が変わらなければ、さらに同じ AX 書き込みを
        // 繰り返しても結果は変わらない。文字セル単位の端末や最小寸法に当たった窓で
        // 操作のたびに3往復していたため、ここで早く収束させる。
        if let previous,
            Geometry.isApproximatelyEqual(previous.observed, observed, tolerance: tolerance)
        {
            attempts.removeValue(forKey: id)
            return .giveUp(.unchangedResult)
        }

        let retryCount = (previous?.retryCount ?? 0) + 1
        guard retryCount <= maxCorrections else {
            attempts.removeValue(forKey: id)
            return .giveUp(.exhausted)
        }

        attempts[id] = Attempt(
            target: target, observed: observed, retryCount: retryCount)
        return .retry(retryCount)
    }

    mutating func forget(_ id: CGWindowID) {
        attempts.removeValue(forKey: id)
    }
}
