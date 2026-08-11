import AppKit
import CoreGraphics
import CometCore
import CometSupport

/// 内蔵UI の入口。`Engine` からの合図を受けて3つの表示を動かす。
///
/// `Engine` はここに依存しない（`CometCore` は AppKit の表示を知らない）。
/// 配線は `main.swift` が行い、`Engine` はクロージャで合図だけを出す。
@MainActor
public final class DecorationController {

    public let border: FocusBorder
    public let indicator: WorkspaceIndicator
    public let wallpaper: WallpaperService

    private var workspaceCount: Int
    private let log: Log

    public init(
        border: BorderStyle = BorderStyle(),
        indicator: IndicatorStyle = .both,
        hudDuration: TimeInterval = 0.4,
        workspaceCount: Int = 10,
        log: Log = .shared
    ) {
        self.border = FocusBorder(style: border, log: log)
        self.indicator = WorkspaceIndicator(
            style: indicator, hudDuration: hudDuration, log: log)
        self.wallpaper = WallpaperService(log: log)
        self.workspaceCount = workspaceCount
        self.log = log
    }

    /// 壁紙の設定を読み込む。存在しないパスは捨てられる。
    public func loadWallpapers(_ paths: [WorkspaceID: String]) {
        wallpaper.load(paths)
    }

    /// フォーカス中のウィンドウの矩形（AX 座標）が決まった。
    ///
    /// **AX の適用完了を待たずに呼ばれる。** 枠線が先に着地することで遅延が視覚的に隠れる。
    public func focusedFrameChanged(to rect: CGRect?) {
        guard let rect else {
            // フォーカス先が無い状態を「枠線が消える」ことで明示する。
            border.hide()
            return
        }
        border.show(around: rect)
    }

    /// 表示するワークスペースが変わった。
    ///
    /// **壁紙とインジケータはウィンドウ移動の発行より先に更新する。**
    /// どちらも自プロセス側の処理なので即座に終わり、切替が速く見える（症状D）。
    public func workspaceChanged(to workspace: WorkspaceID) {
        wallpaper.apply(for: workspace)
        indicator.update(to: workspace, of: workspaceCount)
    }

    public func stop() {
        border.hide()
        indicator.stop()
    }
}
