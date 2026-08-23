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
    /// フォーカスしていないタイルの枠線。`[border] color-unfocused` を書いたときだけ描く。
    public let tileBorders: TileBorders
    public let indicator: WorkspaceIndicator
    public let wallpaper: WallpaperService

    private var workspaceCount: Int
    /// ワークスペース番号 → 名前。インジケータの表示にだけ使う。
    public var workspaceNames: [WorkspaceID: String] = [:] {
        didSet { indicator.names = workspaceNames }
    }
    private let log: Log

    public init(
        border: BorderStyle = BorderStyle(),
        indicator: IndicatorStyle = .both,
        hudDuration: TimeInterval = 0.4,
        workspaceCount: Int = 10,
        log: Log = .shared
    ) {
        self.border = FocusBorder(style: border, log: log)
        self.tileBorders = TileBorders(style: border, log: log)
        self.indicator = WorkspaceIndicator(
            style: indicator, hudDuration: hudDuration, log: log)
        self.wallpaper = WallpaperService(log: log)
        self.workspaceCount = workspaceCount
        self.log = log
    }

    /// 壁紙の設定を読み込む。存在しないパスは捨てられる。
    ///
    /// - Parameters:
    ///   - paths: ワークスペースごとの個別指定。
    ///   - directory: 画像を入れたディレクトリ。名前順に割り当て、足りなければ繰り返す。
    public func loadWallpapers(
        _ paths: [WorkspaceID: String], directory: String? = nil, workspaceCount: Int? = nil
    ) {
        wallpaper.load(
            paths, directory: directory, workspaceCount: workspaceCount ?? self.workspaceCount)
    }

    /// フォーカスしていないタイルの矩形が変わった。
    public func tiledFramesChanged(_ frames: [(id: CGWindowID, frame: CGRect)]) {
        tileBorders.update(frames)
    }

    /// フォーカス中のウィンドウが決まった。
    ///
    /// **AX の適用完了を待たずに呼ばれる。** 枠線が先に着地することで遅延が視覚的に隠れる。
    public func focusedFrameChanged(to focused: FocusedWindow?) {
        guard let focused else {
            // フォーカス先が無い状態を「枠線が消える」ことで明示する。
            border.hide()
            return
        }
        border.show(around: focused.frame, windowID: focused.id)
    }

    /// ワークスペースの見え方が変わった。
    ///
    /// **壁紙とインジケータはウィンドウ移動の発行より先に更新する。**
    /// どちらも自プロセス側の処理なので即座に終わり、切替が速く見える（症状D）。
    ///
    /// 2画面では壁紙もインジケータもモニタごとに違うので、状態をまとめて受ける。
    public func workspaceStatusChanged(_ status: WorkspaceStatus) {
        wallpaper.apply(
            assignments: status.visible.map {
                (monitor: $0.monitor, workspace: $0.workspace)
            })
        indicator.update(status)
    }

    public func stop() {
        border.hide()
        tileBorders.stop()
        indicator.stop()
    }
}
