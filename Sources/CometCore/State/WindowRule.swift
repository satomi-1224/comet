import CoreGraphics

/// ウィンドウルール。条件に当てはまるウィンドウの扱いを変える。
public struct WindowRule: Sendable, Equatable {

    public enum Action: String, Sendable, Equatable {
        /// タイル管理下に置くが並べない（`run = "layout floating"`）。
        case float
    }

    /// バンドル ID の完全一致。
    public var appID: String?
    /// タイトルの部分一致。正規表現ではない。
    public var titleSubstring: String?
    public var action: Action

    public init(appID: String?, titleSubstring: String?, action: Action) {
        self.appID = appID
        self.titleSubstring = titleSubstring
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
        return appID != nil || titleSubstring != nil
    }
}
