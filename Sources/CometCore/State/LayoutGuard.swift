import CoreGraphics
import Foundation

/// 目標からずれたウィンドウを戻し続けるための、諦めどころの管理。
///
/// **戻すこと自体は強くやりたいが、勝てない相手と延々と押し合ってはいけない。**
/// 文字セル単位でしかリサイズできない端末や、自分で位置を決め直すアプリが相手だと、
/// 戻す → ずれる → 戻す、が止まらず CPU とログを食い潰す。
///
/// 同じウィンドウを続けて戻しても直らないなら一旦手を引き、しばらくしてから
/// また試す。利用者がドラッグして戻した直後のような**一度で直る場合には
/// 一切影響しない**（成功したら数え直す）。
struct LayoutGuard {

    /// 続けて何回まで戻すか。
    static let maxAttempts = 4
    /// 諦めたあと、次に試すまでの間隔（秒）。
    static let backoff: TimeInterval = 20

    private struct State {
        var attempts: Int
        var pausedUntil: Double?
    }

    private var states: [CGWindowID: State] = [:]

    enum Decision: Equatable {
        /// 戻す。
        case restore
        /// 諦めた瞬間。**ここでだけ利用者に伝える**（毎回言うとログが埋まる）。
        case giveUp
        /// 諦めたあとの休み中。黙って見送る。
        case wait
    }

    /// 今このウィンドウを戻してよいか。
    ///
    /// - Parameter now: 単調増加する時刻（秒）。
    mutating func decide(_ id: CGWindowID, now: Double) -> Decision {
        var state = states[id] ?? State(attempts: 0, pausedUntil: nil)
        if let until = state.pausedUntil {
            guard now >= until else { return .wait }
            // 休み明け。数え直してもう一度試す。
            state = State(attempts: 0, pausedUntil: nil)
        }
        state.attempts += 1
        if state.attempts > Self.maxAttempts {
            states[id] = State(attempts: 0, pausedUntil: now + Self.backoff)
            return .giveUp
        }
        states[id] = state
        return .restore
    }

    /// 目標どおりになっていた。数え直す。
    mutating func settled(_ id: CGWindowID) {
        states.removeValue(forKey: id)
    }

    mutating func forget(_ id: CGWindowID) {
        states.removeValue(forKey: id)
    }

    /// 目標と実際がずれているか。
    ///
    /// **位置と大きさの両方を見る。** 位置だけだと、掴んで広げられたウィンドウが
    /// 「動いていない」と判定されて戻らない。
    static func isOff(_ actual: CGRect, from desired: CGRect, tolerance: CGFloat = 2) -> Bool {
        !Geometry.isApproximatelyEqual(actual, desired, tolerance: tolerance)
    }
}
