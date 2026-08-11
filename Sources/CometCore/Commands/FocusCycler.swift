import CoreGraphics
import Darwin
import Foundation

/// 巡回の対象。
public enum FocusCycleTarget: String, Sendable, Equatable, CaseIterable {
    /// 次のアプリのウィンドウへ（最近使った順）。
    case nextApp = "next-app"
    case previousApp = "prev-app"
    /// 同じアプリの次のウィンドウへ。
    case nextWindowInApp = "next-window-in-app"
    case previousWindowInApp = "prev-window-in-app"

    /// アプリをまたぐ巡回か。またぐものだけ「押し続けている間の並び」を保つ。
    public var isAcrossApps: Bool { self == .nextApp || self == .previousApp }
    public var isForward: Bool { self == .nextApp || self == .nextWindowInApp }
}

/// アプリ巡回とアプリ内のウィンドウ巡回。**純粋な計算だけ。**
///
/// Hammerspoon の `Alt+F` / `Alt+D` を comet 側へ移したもの（設計書 §12.3）。
/// WM が既に持っているウィンドウ一覧を使うので、二重管理が無くなる。
public enum FocusCycler {

    /// 巡回の候補になるウィンドウ1枚分。
    public struct Candidate: Equatable, Sendable {
        public let id: CGWindowID
        public let pid: pid_t
        /// 最後にフォーカスした順番（大きいほど最近）。まだなら 0。
        public let lastFocusedAt: UInt64

        public init(id: CGWindowID, pid: pid_t, lastFocusedAt: UInt64) {
            self.id = id
            self.pid = pid
            self.lastFocusedAt = lastFocusedAt
        }
    }

    /// アプリを最近使った順に並べ、各アプリの代表ウィンドウを返す。
    ///
    /// 代表は**そのアプリで最後に使ったウィンドウ**。アプリへ戻ったときに
    /// 直前に見ていたウィンドウが出てくるほうが自然。
    public static func appOrder(_ candidates: [Candidate]) -> [CGWindowID] {
        var newest: [pid_t: Candidate] = [:]
        for candidate in candidates {
            if let existing = newest[candidate.pid], existing.lastFocusedAt >= candidate.lastFocusedAt {
                continue
            }
            newest[candidate.pid] = candidate
        }
        // 同着（まだ一度もフォーカスしていない）でも順番が揺れないよう id で決める。
        return newest.values
            .sorted {
                $0.lastFocusedAt == $1.lastFocusedAt
                    ? $0.id < $1.id : $0.lastFocusedAt > $1.lastFocusedAt
            }
            .map(\.id)
    }

    /// 同じアプリのウィンドウ。**固定の輪にするため id の昇順。**
    ///
    /// 最近使った順にすると2枚の間を往復するだけになり、3枚以上あるときに
    /// 残りへ行けない。
    public static func windowsInApp(_ candidates: [Candidate], pid: pid_t) -> [CGWindowID] {
        candidates.filter { $0.pid == pid }.map(\.id).sorted()
    }

    /// 並びの中で次（または前）を選ぶ。
    ///
    /// 今の位置が並びに無ければ先頭。要素が1つ以下なら `nil`（動かす先が無い）。
    public static func next(in order: [CGWindowID], from current: CGWindowID?, forward: Bool)
        -> CGWindowID?
    {
        guard order.count > 1 else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return order.first }
        let step = forward ? 1 : -1
        let next = (index + step + order.count) % order.count
        return order[next]
    }

    /// 押し続けている間の巡回の状態。
    ///
    /// **並びを組み直さないことが肝。** フォーカスすると最近使った順が変わるので、
    /// 毎回組み直すと2つのアプリの間を往復するだけになる（Hammerspoon 版も
    /// 1.5 秒だけ並びを保持していた）。
    public struct Session {

        /// 続きとして辿っている並び。
        private var order: [CGWindowID] = []
        /// 今どこを指しているか。
        private var index: Int = 0
        /// 最後に進めた時刻。
        private var touchedAt: TimeInterval = -.infinity

        public init() {}

        /// 次に選ぶウィンドウ。
        ///
        /// - Parameters:
        ///   - order: 最近使った順に組み直した並び。続きが有効なら使われない。
        ///   - now: 単調増加の秒数。
        ///   - resetAfter: 続きとみなす時間。0 なら毎回組み直す。
        public mutating func advance(
            order candidates: [CGWindowID], now: TimeInterval, resetAfter: TimeInterval,
            forward: Bool
        ) -> CGWindowID? {
            guard candidates.count > 1 else {
                self.order = []
                return nil
            }

            // 続きとして使えるのは「時間内」かつ「並びの顔ぶれが変わっていない」とき。
            // 閉じたウィンドウを掴んだままだと、消えたウィンドウへフォーカスしようとする。
            let isFresh = now - touchedAt <= resetAfter
            let sameMembers = Set(order) == Set(candidates)
            if !(isFresh && sameMembers && order.count > 1) {
                order = candidates
                index = 0
            }

            let step = forward ? 1 : -1
            index = (index + step + order.count) % order.count
            touchedAt = now
            return order[index]
        }
    }
}

/// 巡回の対象範囲。
public enum FocusCycleScope: String, Sendable, Equatable, CaseIterable {
    /// 表示中のワークスペースのウィンドウだけ。
    ///
    /// 非表示のものまで含めると、巡回のたびにワークスペースが飛ぶ
    /// （`focus-follows-activation` が働くため）。
    case activeWorkspace = "workspace"
    /// 全ワークスペース。行き先のワークスペースへ自動で切り替わる。
    case allWorkspaces = "all"
}
