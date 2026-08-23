import CoreGraphics
import Darwin

/// 非表示ワークスペースのウィンドウの隠し方。
public enum HiddenWindowStrategy: String, Sendable, Equatable, CaseIterable {

    /// 画面の隅へ追い込む。
    ///
    /// **1pt × 46pt の角が残る。** macOS はウィンドウを画面外へ出させないため、
    /// これが位置操作だけでできる限界（`Geometry.stashOrigin` を参照）。
    case offScreen = "off-screen"

    /// アプリごと非表示にする（Cmd+H 相当）。
    ///
    /// **完全に消え、Mission Control にも出ない。** ただし粒度がアプリ単位なので、
    /// そのアプリの管理下ウィンドウが**すべて**非表示ワークスペースにあるときしか使えない。
    /// 表示中のワークスペースにも window を持つアプリは隅寄せに落ちる。
    case hideApp = "hide-app"
}

/// どのアプリを非表示にし、どのウィンドウを隅へ寄せるかを決める。**純粋関数。**
///
/// アプリ単位の非表示は「全ウィンドウが隠れているアプリ」にしか使えない。
/// 判定を間違えると**見ているワークスペースのウィンドウまで消える**ので、
/// ここだけはテストで固めておく。
public enum HidePlanner {

    /// 判定に使うウィンドウ1枚分の情報。
    public struct Window: Equatable, Sendable {
        public let id: CGWindowID
        public let pid: pid_t
        public let workspace: WorkspaceID
        /// ワークスペースに関係なく常に画面に出ているか（サブディスプレイ上のウィンドウ）。
        ///
        /// **これを持つアプリはアプリごと隠せない。** `NSRunningApplication.hide()` は
        /// アプリの全ウィンドウを消すので、隠すとサブディスプレイのウィンドウまで消える。
        /// 隅寄せの対象にもしない（サブディスプレイは触らない方針）。
        public let isAlwaysVisible: Bool

        public init(
            id: CGWindowID, pid: pid_t, workspace: WorkspaceID, isAlwaysVisible: Bool = false
        ) {
            self.id = id
            self.pid = pid
            self.workspace = workspace
            self.isAlwaysVisible = isAlwaysVisible
        }
    }

    public struct Plan: Equatable, Sendable {
        /// 非表示にするアプリ。
        public var hide: [pid_t] = []
        /// 表示へ戻すアプリ。
        public var unhide: [pid_t] = []
        /// アプリ単位で隠せないので個別に隅へ寄せるウィンドウ。
        public var stash: [CGWindowID] = []

        public var isEmpty: Bool { hide.isEmpty && unhide.isEmpty && stash.isEmpty }
    }

    /// - Parameters:
    ///   - windows: 位置を触りうるウィンドウ（タイルとフローティング）。
    ///   - visibleWorkspaces: 今どこかのモニタに映っているワークスペース。
    ///     **複数ある**（モニタ1台につき1つ）。1つだけと決め打つと、2画面のうち
    ///     片方に映っているウィンドウまで隠してしまう。
    ///   - hiddenApps: 今 macOS 側で非表示になっているアプリ。
    ///     利用者が Cmd+Tab で戻した場合に追従するため、**自分の記録ではなく実態を渡す**。
    public static func plan(
        windows: [Window],
        visibleWorkspaces: Set<WorkspaceID>,
        hiddenApps: Set<pid_t>,
        strategy: HiddenWindowStrategy
    ) -> Plan {
        var plan = Plan()

        // PID ごとにまとめる。並び順は入力順を保つ（ログと適用順を決定的にするため）。
        var order: [pid_t] = []
        var grouped: [pid_t: [Window]] = [:]
        for window in windows {
            if grouped[window.pid] == nil {
                order.append(window.pid)
            }
            grouped[window.pid, default: []].append(window)
        }

        for pid in order {
            guard let owned = grouped[pid] else { continue }
            let hiddenHere = owned.filter {
                !$0.isAlwaysVisible && !visibleWorkspaces.contains($0.workspace)
            }
            let canHideApp =
                strategy == .hideApp && !hiddenHere.isEmpty && hiddenHere.count == owned.count

            if canHideApp {
                // 全ウィンドウが隠れている。アプリごと消せる。
                if !hiddenApps.contains(pid) {
                    plan.hide.append(pid)
                }
                continue
            }

            // 表示すべきウィンドウが1枚でもあるなら、アプリは表示に戻さないといけない。
            // ここを飛ばすと「切り替えたのに何も出てこない」状態になる。
            if hiddenApps.contains(pid) {
                plan.unhide.append(pid)
            }
            plan.stash.append(contentsOf: hiddenHere.map(\.id))
        }
        return plan
    }
}
