import AppKit
import Foundation
import CometCore
import CometSupport

/// ワークスペースごとの壁紙。**症状D（壁紙変更がワンテンポ遅れる）の対策そのもの。**
///
/// 現行の `osascript` 経由（bash 起動 + AppleScript 処理系の初期化 + System Events への
/// AppleEvent）は概ね 0.2〜1.5 秒かかる。`NSWorkspace.setDesktopImageURL` を
/// プロセス内で直接呼べば数 ms で済む（設計書 §2.2, §8.3）。
@MainActor
public final class WallpaperService {

    /// ワークスペース → 壁紙。**実在するものだけが入る。**
    private var urls: [WorkspaceID: URL] = [:]
    private var lastApplied: WorkspaceID?
    private let log: Log

    public init(log: Log = .shared) {
        self.log = log
    }

    public var configuredCount: Int { urls.count }

    /// 設定を読み込む。
    ///
    /// 存在しないパスは捨てて警告する。切替のたびに存在を確かめるのは無駄なので、
    /// 検証は**起動時に一度だけ**行う。
    public func load(_ paths: [WorkspaceID: String]) {
        let resolved = Self.resolve(paths)
        urls = resolved.urls
        for (workspace, path) in resolved.missing.sorted(by: { $0.key < $1.key }) {
            log.warn("ワークスペース \(workspace) の壁紙が見つからない: \(path)")
        }
        if !urls.isEmpty {
            log.info("壁紙を \(urls.count) 件登録した")
        }
    }

    /// 壁紙を切り替える。**未設定のワークスペースでは何もしない。**
    ///
    /// `setDesktopImageURL` は内部で非同期に処理されるので呼び出しは即座に返る。
    /// ワークスペース切替の最初期（ウィンドウ移動の発行前）に呼ぶこと。
    public func apply(for workspace: WorkspaceID) {
        guard let url = urls[workspace] else { return }
        guard lastApplied != workspace else { return }
        lastApplied = workspace

        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                log.warn("壁紙を設定できなかった: \(url.lastPathComponent): \(error)")
            }
        }
        log.debug("壁紙を切り替えた: ワークスペース \(workspace) → \(url.lastPathComponent)")
    }

    // MARK: - パスの解決（純粋）

    /// パスを展開し、実在するものだけを残す。
    ///
    /// - Parameter fileExists: 差し替え可能にしてあるのはテストのため。
    public nonisolated static func resolve(
        _ paths: [WorkspaceID: String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (urls: [WorkspaceID: URL], missing: [WorkspaceID: String]) {
        var urls: [WorkspaceID: URL] = [:]
        var missing: [WorkspaceID: String] = [:]

        for (workspace, path) in paths {
            let expanded = expand(path)
            guard !expanded.isEmpty, fileExists(expanded) else {
                missing[workspace] = path
                continue
            }
            urls[workspace] = URL(fileURLWithPath: expanded)
        }
        return (urls, missing)
    }

    /// `~` と `~/` を展開する。`~user` 形式は扱わない（設定で使う意味がない）。
    nonisolated static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return trimmed == "~" ? home : home + String(trimmed.dropFirst())
    }
}
