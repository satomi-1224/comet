import CoreGraphics
import Darwin

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
        /// 持ち主のプロセス。**取りこぼしたウィンドウを見つけるのに使う。**
        ///
        /// AX の生成通知は取りこぼしうる（生まれた直後の要素は ID も属性も返さない
        /// ことがある）。一覧側に持ち主が分かれば「監視しているアプリなのに台帳に
        /// 無いウィンドウ」を検出して走査し直せる。
        public let ownerPID: pid_t

        public init(layer: Int, bounds: CGRect, ownerPID: pid_t = 0) {
            self.layer = layer
            self.bounds = bounds
            self.ownerPID = ownerPID
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
            let owner = (info[kCGWindowOwnerPID as String] as? pid_t) ?? 0
            entries[id] = Entry(layer: layer, bounds: rect, ownerPID: owner)
        }
        return entries
    }

    public static func layer(of id: CGWindowID) -> Int? {
        snapshot()?[id]?.layer
    }

    /// 候補のうち、画面一覧で通常より上の階層にいるウィンドウ。
    ///
    /// 候補の順序を保つ。一覧にいない（まだ表示前、別 Space、取得失敗）ものは、
    /// 階層が分からないので含めない。
    static func elevatedWindowIDs(
        in screen: [CGWindowID: Entry], among candidates: [CGWindowID]
    ) -> [CGWindowID] {
        candidates.filter { id in
            guard let layer = screen[id]?.layer else { return false }
            return layer != normalLayer
        }
    }

    /// 表示前に生成通知が来た新規ウィンドウを、画面一覧へ現れるまで待つか。
    ///
    /// 一覧そのものの取得失敗も「まだ見えない」と同じく再試行する。ただし、特殊な
    /// ウィンドウを永久に取りこぼさないよう最後の試行では取り込みへ進む。
    static func shouldWaitForVisibility(
        of id: CGWindowID,
        in screen: [CGWindowID: Entry]?,
        attempt: Int,
        maxAttempts: Int
    ) -> Bool {
        screen?[id] == nil && attempt < maxAttempts
    }
}
