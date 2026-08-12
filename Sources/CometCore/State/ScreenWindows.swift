import CoreGraphics

/// 画面上のウィンドウを `CGWindowList` から読む。
///
/// **AX とは別系統の観測。** AX の往復（相手アプリのメインスレッドとの同期 IPC）が
/// 要らず、全ウィンドウぶんの階層と矩形が1回で取れる。相手がハングしていても
/// こちらは止まらない。
///
/// 使いどころは2つ:
/// - **並べる対象かの判定**（`layer`）。ピクチャーインピクチャの窓は AX 上ふつうの
///   ウィンドウに見え、role でも subrole でも大きさでも見分けられない。
///   通常のウィンドウが 0、常に手前へ出る窓が 3 という階層だけが手がかりになる。
/// - **レイアウトの見張り**（`bounds`）。目標どおりに並んでいるかを、AX を叩かずに
///   確かめられる。
public enum ScreenWindows {

    /// 通常のウィンドウの階層。
    public static let normalLayer = 0

    public struct Entry: Equatable, Sendable {
        public let layer: Int
        /// 左上原点。AX と同じ向きなのでそのまま突き合わせられる。
        public let bounds: CGRect

        public init(layer: Int, bounds: CGRect) {
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// 画面に出ているウィンドウ。
    ///
    /// **画面外のものは含めない。** 画面外を含む `optionAll` は実測 4.4ms（110枚）で、
    /// 新規ウィンドウが着地するまでの予算（実測 14〜36ms）を大きく削る。
    /// 画面上だけなら 0.3ms で済む。取りこぼしたウィンドウは「分からない」となり
    /// 従来どおり扱われるので害は無い。
    ///
    /// - Returns: 取得に失敗したときは `nil`。**空の辞書と区別する。**
    public static func snapshot() -> [CGWindowID: Entry]? {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        return parse(list)
    }

    /// 一覧から組み立てる。**判定はここに閉じてテストできるようにする。**
    static func parse(_ list: [[String: Any]]) -> [CGWindowID: Entry] {
        var entries: [CGWindowID: Entry] = [:]
        entries.reserveCapacity(list.count)
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                let layer = info[kCGWindowLayer as String] as? Int
            else { continue }
            var rect = CGRect.zero
            if let raw = info[kCGWindowBounds as String] as? [String: Any],
                let parsed = CGRect(dictionaryRepresentation: raw as CFDictionary)
            {
                rect = parsed
            }
            entries[id] = Entry(layer: layer, bounds: rect)
        }
        return entries
    }

    public static func layer(of id: CGWindowID) -> Int? {
        snapshot()?[id]?.layer
    }
}
