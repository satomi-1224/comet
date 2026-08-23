import Foundation

/// ウィンドウルール。条件に当てはまるウィンドウの扱いを変える。
///
/// i3 の `for_window [criteria] <command>` と `assign [criteria] → workspace N` に相当する。
/// **当てるのは初めて見るウィンドウのときだけ**（``Engine`` 側の約束）。あとから
/// 当て直すと、利用者が手で戻した選択を上書きしてしまう。
public struct WindowRule: Sendable, Equatable {

    public enum Action: Sendable, Equatable {
        /// タイル管理下に置くが並べない（`run = "layout floating"`）。
        case float
        /// 決まったワークスペースへ入れる（`run = "move-node-to-workspace 3"`）。
        ///
        /// i3 の `assign`。ブラウザは 2、端末は 3、のように置き場所を固定できる。
        case moveToWorkspace(WorkspaceID)
    }

    /// バンドル ID の完全一致。
    public var appID: String?
    /// タイトルの部分一致。正規表現ではない。
    public var titleSubstring: String?
    /// タイトルの正規表現（`if-window-title-regex`）。
    ///
    /// **解釈できるかは読み込み時に確かめてある。** ここで解釈に失敗した場合は
    /// 「当たらない」として扱う。当たってしまうより空振りのほうが害が小さい。
    public var titleRegex: String?
    public var action: Action

    public init(
        appID: String?, titleSubstring: String?, titleRegex: String? = nil, action: Action
    ) {
        self.appID = appID
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.action = action
    }

    /// 書かれている条件を**すべて**満たすか。
    ///
    /// 条件が空のルールは全ウィンドウに当たってしまうので、読み込み時に拒否している。
    public func matches(bundleID: String?, title: String?) -> Bool {
        if let appID {
            guard bundleID == appID else { return false }
        }
        if let titleSubstring {
            guard let title, title.contains(titleSubstring) else { return false }
        }
        if let titleRegex {
            guard let title, Self.matches(regex: titleRegex, in: title) else { return false }
        }
        return appID != nil || titleSubstring != nil || titleRegex != nil
    }

    /// 正規表現が当たるか。**部分一致**（i3 の criteria と同じ）。
    ///
    /// 組み立てた `NSRegularExpression` は使い回す。ルールを当てるのは新しい
    /// ウィンドウを見つけたときだけだが、ブラウザのように何十枚も開くアプリでは
    /// 積み上がる。
    static func matches(regex pattern: String, in title: String) -> Bool {
        guard let expression = compiled(pattern) else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return expression.firstMatch(in: title, range: range) != nil
    }

    /// 解釈できる正規表現か。読み込み時の検証に使う。
    public static func isValidRegex(_ pattern: String) -> Bool {
        compiled(pattern) != nil
    }

    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        cache.withLock { store in
            if let existing = store[pattern] { return existing.value }
            let expression = try? NSRegularExpression(pattern: pattern)
            store[pattern] = Box(expression)
            return expression
        }
    }

    /// `nil` も「作れなかった」として覚えるための入れ物。
    private struct Box: Sendable {
        let value: NSRegularExpression?
        init(_ value: NSRegularExpression?) { self.value = value }
    }

    private static let cache = Locked<[String: Box]>([:])
}

/// 錠付きの値。`NSRegularExpression` の使い回しを並行境界を越えて行うために持つ。
///
/// - Note: 標準の `Synchronization.Mutex` は macOS 15 以降なので、14 を対象に
///   できるように自前で用意する。名前を変えてあるのは、将来 `Synchronization` を
///   読み込んだときに取り違えないため。
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
