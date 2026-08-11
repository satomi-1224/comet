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
    ///
    /// - Parameters:
    ///   - paths: ワークスペースごとの個別指定。ディレクトリより優先する。
    ///   - directory: 画像を入れたディレクトリ。名前順に割り当てる。
    ///   - workspaceCount: 割り当て先の数。
    public func load(
        _ paths: [WorkspaceID: String], directory: String? = nil, workspaceCount: Int = 10
    ) {
        let fromDirectory =
            directory.map { Self.plan(directory: $0, workspaceCount: workspaceCount) } ?? [:]
        if let directory, !directory.isEmpty, fromDirectory.isEmpty {
            // **無いだけなら警告しない。** 既定の設定に書いてあるパスなので、
            // 画像を置いていない利用者には普通の状態。毎回警告すると狼少年になる。
            // 一方「ディレクトリはあるのに画像が無い」は綴り間違いの可能性がある。
            let exists = FileManager.default.fileExists(atPath: Self.expand(directory))
            let message = "壁紙のディレクトリに画像が無いので壁紙は変えない: \(directory)"
            if exists { log.warn(message) } else { log.debug(message) }
        } else if !fromDirectory.isEmpty {
            log.info(
                "壁紙のディレクトリから \(Set(fromDirectory.values).count) 枚を "
                    + "\(fromDirectory.count) ワークスペースへ割り当てた: \(directory ?? "")")
        }

        let resolved = Self.resolve(Self.merge(directory: fromDirectory, explicit: paths))
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

    // MARK: - ディレクトリからの割り当て（純粋）

    /// 壁紙として扱う拡張子。
    ///
    /// ディレクトリには `.DS_Store` やメモが紛れる。**画像だけを数える**ようにしないと、
    /// 「3枚入れたのに 4 ワークスペース目からずれる」といった分かりにくい挙動になる。
    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
    ]

    /// ディレクトリの中身をワークスペースへ割り当てる。
    ///
    /// **名前順に最大 `workspaceCount` 枚を採り、足りなければ先頭から繰り返す**
    /// （3枚 / 10ワークスペースなら 1231231231）。
    ///
    /// 画像が1枚も無い、ディレクトリを読めない、指定が空のときは**空を返す**。
    /// 呼び出し側はそのまま「壁紙を変えない」ことになる。中途半端に変えるより、
    /// 変えないほうが利用者にとって分かりやすい。
    ///
    /// - Parameter contents: ディレクトリの中身。差し替え可能にしてあるのはテストのため。
    ///   読めないときは `nil` を返す。
    public nonisolated static func plan(
        directory: String,
        workspaceCount: Int,
        contents: (String) -> [String]? = {
            try? FileManager.default.contentsOfDirectory(atPath: $0)
        }
    ) -> [WorkspaceID: String] {
        let path = expand(directory)
        guard !path.isEmpty, workspaceCount > 0, let names = contents(path) else { return [:] }

        // 「名前順」は Finder の並びと同じ自然順にする。辞書順では
        // wallpaper10 が wallpaper2 より前に来て、利用者の意図とずれる。
        let images =
            names
            .filter { !$0.hasPrefix(".") && imageExtensions.contains($0.pathExtensionLowercased) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(workspaceCount)
        guard !images.isEmpty else { return [:] }

        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        var assigned: [WorkspaceID: String] = [:]
        for workspace in 1...workspaceCount {
            assigned[workspace] = base + "/" + images[(workspace - 1) % images.count]
        }
        return assigned
    }

    /// ディレクトリからの割り当てに個別指定を重ねる。**個別指定が勝つ。**
    ///
    /// ディレクトリで大枠を決めつつ、特定のワークスペースだけ差し替えられるようにする。
    public nonisolated static func merge(
        directory: [WorkspaceID: String], explicit: [WorkspaceID: String]
    ) -> [WorkspaceID: String] {
        directory.merging(explicit) { _, override in override }
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
    public nonisolated static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return trimmed == "~" ? home : home + String(trimmed.dropFirst())
    }
}

extension String {
    /// 拡張子を小文字で取り出す。`URL` を経由すると `?` を含む名前で挙動が変わるので使わない。
    fileprivate var pathExtensionLowercased: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return "" }
        return String(self[index(after: dot)...]).lowercased()
    }
}
