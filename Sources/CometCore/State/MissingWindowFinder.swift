import CoreGraphics
import Darwin

/// 台帳に無いウィンドウを見つけて、走査し直すアプリを選ぶ。**純粋な計算だけ。**
///
/// ## なぜ要るのか
///
/// AX の生成通知（`AXWindowCreated`）は取りこぼしうる。生まれた直後の要素は
/// ウィンドウ ID も属性も返さないことがあり（ブラウザや Electron 製アプリで起きる）、
/// そこで諦めるとそのウィンドウには**個別の通知も張られない**。移動も破棄も
/// 届かないので、以後どの経路からも拾えず「並ばないウィンドウ」が残る。
///
/// `CGWindowList` は全ウィンドウを 0.3ms で返すうえ AX の往復が要らないので、
/// 「監視しているアプリなのに台帳に無い」窓を定期的に探して走査し直せる。
///
/// ## 空振りと付き合わない
///
/// 何度走査しても拾えない窓もある（ID を取れない疑似ウィンドウなど）。
/// 同じ ID について試す回数に上限を置き、上限に達したら数えるのをやめる。
/// 画面から消えたか台帳に載ったウィンドウの記録は捨てる。
public struct MissingWindowFinder {

    /// 同じウィンドウについて走査し直す回数の上限。
    public let maxAttempts: Int
    /// これ未満のウィンドウは探さない。判定側の下限と揃える。
    public let minimumSize: CGSize

    private var attempts: [CGWindowID: Int] = [:]

    public init(maxAttempts: Int = 3, minimumSize: CGSize = WindowClassifier.minimumSize) {
        self.maxAttempts = maxAttempts
        self.minimumSize = minimumSize
    }

    /// 上限に達して見送ったウィンドウ。診断用。
    public var abandonedCount: Int {
        attempts.values.filter { $0 >= maxAttempts }.count
    }

    /// 走査し直すアプリを選ぶ。
    ///
    /// - Parameters:
    ///   - screen: 画面のウィンドウ一覧（``ScreenWindows/snapshot()``）。
    ///   - known: 台帳にあるウィンドウ。**管理対象外のものも含めること。**
    ///     含めないと、ダイアログを見つけるたびに走査し直すことになる。
    ///   - monitored: 監視しているアプリ。知らないアプリは走査できない。
    ///   - own: 自プロセス。自分のウィンドウ（枠線や HUD）は対象にしない。
    /// - Returns: 走査し直すアプリ。**昇順**（ログと副作用の順序を決定的にする）。
    public mutating func owners(
        screen: [CGWindowID: ScreenWindows.Entry],
        known: (CGWindowID) -> Bool,
        monitored: (pid_t) -> Bool,
        own: pid_t
    ) -> [pid_t] {
        var targets: Set<pid_t> = []

        // 反復順を決定的にするため ID 昇順で見る。回数の増え方が実行ごとに
        // 変わると、上限に達する順序も変わって再現できなくなる。
        for id in screen.keys.sorted() {
            guard let entry = screen[id] else { continue }
            guard entry.layer == ScreenWindows.normalLayer,
                !known(id),
                entry.ownerPID > 0, entry.ownerPID != own,
                monitored(entry.ownerPID),
                entry.bounds.width >= minimumSize.width,
                entry.bounds.height >= minimumSize.height
            else { continue }

            let count = (attempts[id] ?? 0) + 1
            attempts[id] = count
            guard count <= maxAttempts else { continue }
            targets.insert(entry.ownerPID)
        }

        // 台帳に載ったか画面から消えたウィンドウの記録は捨てる。
        // 残すと、同じ ID が別のウィンドウに振られたときに数え始めから始まらない。
        attempts = attempts.filter { screen[$0.key] != nil && !known($0.key) }

        return targets.sorted()
    }

    /// ウィンドウが消えたときに記録を捨てる。
    public mutating func forget(_ id: CGWindowID) {
        attempts.removeValue(forKey: id)
    }
}
