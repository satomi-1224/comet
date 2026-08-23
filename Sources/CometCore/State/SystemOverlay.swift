import AppKit
import CoreGraphics
import Darwin

/// Mission Control / Launchpad / App Exposé が画面を覆っているかの判定。
///
/// ## なぜ要るのか
///
/// これらが開いている間、**ウィンドウは一覧から消えない。縮小されて並べ替えられる**
///（実測: (962,28) 955x959 のウィンドウが (968,86) 893x896 になる）。
/// 知らずにいると2つの症状が出る。
///
/// 1. **枠線が何も無いところに浮く。** 元の位置に線が残る。
/// 2. **comet が配置を戻そうとして Mission Control と押し合う。**
///    実測で 2 秒間に 24 回の AX 書き込みが飛び、そのうえ見張りが
///    「戻しても直らない相手」と判断して**その後 20 秒間ずっと停止する**
///    （閉じた直後に本当にずれても直さなくなる）。
///
/// ## 見分け方
///
/// AX にも `NSWorkspace` にも通知が無い（実測）。手がかりは
/// **Dock が画面いっぱいの覆いを出すこと**だけ。
///
/// | 状態 | 画面を覆う Dock のウィンドウ |
/// |---|---|
/// | 通常（1920x1080 ×2 台） | 1 枚（レベル 20、常設） |
/// | Mission Control（同上） | 5 枚（レベル 18 と 20 が画面ごとに増える） |
/// | 通常（2560x1664 ×1 台） | 0 枚 |
/// | Mission Control（同上） | 2 枚（レベル 18 と 20） |
///
/// つまり**常設ぶんが何枚かは環境で違う**。そこで枚数そのものではなく
/// **「画面の数より多いか」**で見る。上の4通りすべてで正しく判定できる。
///
/// - Important: `kCGWindowName`（"Dock" という名前が付くのは常設のものだけ）では
///   見分けられない。**ウィンドウ名の取得には画面収録の権限が要り**、comet は
///   それを要求しない方針なので常に `nil` になる。
public enum SystemOverlay {

    /// - Parameters:
    ///   - dockWindowSizes: Dock が持っているウィンドウの大きさ。
    ///   - displaySizes: 画面の大きさ。
    /// - Returns: 覆いが出ていると判断できるか。**判断できないときは `false`。**
    ///   誤って `true` にすると枠線が二度と出なくなる（実機でそうなった）。
    public static func isVisible(dockWindowSizes: [CGSize], displaySizes: [CGSize]) -> Bool {
        guard !displaySizes.isEmpty else { return false }
        let covering = dockWindowSizes.count { size in
            displaySizes.contains {
                abs($0.width - size.width) < 2 && abs($0.height - size.height) < 2
            }
        }
        return covering > displaySizes.count
    }

    /// Dock のプロセス。**ウィンドウ名を読まずに Dock のウィンドウを選ぶために使う。**
    ///
    /// 名前の取得には画面収録の権限が要るが、`kCGWindowOwnerPID` には要らない。
    public static func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
    }
}
