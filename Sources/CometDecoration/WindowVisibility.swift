import AppKit
import CoreGraphics

/// 枠線を出してよい状態かを、画面のウィンドウ一覧から判断する。
///
/// **AX からは分からない情報。** Mission Control を開いても、別のアプリが
/// ネイティブ全画面で自分の Space を占めても、Cmd+H で隠されても、AX 上の
/// ウィンドウは生きたまま同じ矩形を返す。枠線は自プロセスのウィンドウで
/// **全 Space に居座る**（`canJoinAllSpaces`）ので、これを見ないと
/// 見えていないウィンドウを囲み続ける（実際にそう報告された）。
///
/// 見分けは2つ要る。**片方だけでは足りないことを実測で確かめた。**
/// - 一覧から消える … Cmd+H、最小化、別 Space（他アプリのネイティブ全画面）
/// - 一覧に残るが画面は別物 … **Mission Control**。ウィンドウは縮小されて
///   並べ替えられるだけで一覧には残る。代わりに Dock が画面全体を覆う窓を出す。
public enum WindowVisibility {

    /// 一度の問い合わせで得た画面の状態。
    public struct Screen: Equatable, Sendable {
        /// 画面に出ているウィンドウ。
        public let onScreen: Set<CGWindowID>
        /// Dock が画面全体を覆っている＝Mission Control・Launchpad・App Exposé。
        ///
        /// この間はウィンドウが縮小して並ぶので、**元の位置に枠線を残すと
        /// 何も無いところに線が浮く**。
        public let systemOverlayIsVisible: Bool

        public init(onScreen: Set<CGWindowID>, systemOverlayIsVisible: Bool) {
            self.onScreen = onScreen
            self.systemOverlayIsVisible = systemOverlayIsVisible
        }
    }

    /// 画面のウィンドウ一覧を**1回だけ**読む。実測で約 0.15ms。
    ///
    /// - Returns: 取得に失敗したときは `nil`。**「1枚も出ていない」と区別する。**
    ///   「分からない」を「消えた」と扱うと枠線が消えたまま戻らない。
    @MainActor
    public static func snapshot() -> Screen? {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        return parse(list, displaySizes: NSScreen.screens.map(\.frame.size))
    }

    /// 一覧から状態を組み立てる。**判定はここに閉じてテストできるようにする。**
    static func parse(_ list: [[String: Any]], displaySizes: [CGSize]) -> Screen {
        var ids: Set<CGWindowID> = []
        ids.reserveCapacity(list.count)
        var overlay = false
        for info in list {
            if let id = info[kCGWindowNumber as String] as? CGWindowID {
                ids.insert(id)
            }
            guard !overlay, (info[kCGWindowOwnerName as String] as? String) == "Dock",
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            // Dock 本体は帯なので画面全体には一致しない。一致するのは
            // Mission Control などが敷く覆いだけ（実測: レベル 18 と 20 の 2560x1664）。
            overlay = displaySizes.contains {
                abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2
            }
        }
        return Screen(onScreen: ids, systemOverlayIsVisible: overlay)
    }

    /// 枠線を出してよいか。
    ///
    /// **分からないときは出す。** 枠線が余分に出るのは目障りな程度だが、
    /// 消えたまま戻らないと「フォーカスが分からない」という本来の役目を失う。
    public static func shouldShowBorder(for id: CGWindowID?, screen: Screen?) -> Bool {
        guard let screen else { return true }
        if screen.systemOverlayIsVisible { return false }
        guard let id else { return true }
        return screen.onScreen.contains(id)
    }
}
