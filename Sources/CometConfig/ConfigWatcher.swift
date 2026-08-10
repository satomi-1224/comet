import Foundation
import CometSupport

/// 設定ファイルの変更を監視する。
///
/// **ファイルと親ディレクトリの両方を見る。** 片方だけでは取りこぼす。
///
/// | 変更の仕方 | 観測できる場所 |
/// |---|---|
/// | エディタが上書き保存する（内容だけ変わる） | **ファイル**への書き込み |
/// | 一時ファイルを作って rename する（vim の既定など） | **ディレクトリ**への書き込み |
/// | home-manager が Nix ストアへのシンボリックリンクを張り替える | **ディレクトリ**への書き込み |
///
/// ファイルの fd だけを掴んでいると、張り替えられた後は古い inode を見続けて
/// 以後の変更に気づけない。ディレクトリの変更を受けたらファイルの監視も張り直す。
@MainActor
public final class ConfigWatcher {

    public var onChange: (@MainActor () -> Void)?

    private let path: String
    private let directory: String
    private let debounce: TimeInterval
    private let log: Log

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// - Parameter debounce: 保存ソフトは1回の保存で複数回書き込む。まとめてから通知する。
    public init(path: String, debounce: TimeInterval = 0.3, log: Log = .shared) {
        self.path = path
        self.directory = (path as NSString).deletingLastPathComponent
        self.debounce = debounce
        self.log = log
    }

    public var watchedDirectory: String { directory }
    public var isWatching: Bool { directorySource != nil || fileSource != nil }
    /// ファイル自体を監視できているか。ファイルが無い間は `false`。
    public var isWatchingFile: Bool { fileSource != nil }

    /// 監視を始める。
    ///
    /// - Returns: ディレクトリかファイルのどちらかを監視できたか。
    @discardableResult
    public func start() -> Bool {
        watchDirectory()
        watchFile()
        if isWatching {
            log.debug("設定の変更を監視: \(path)")
        }
        return isWatching
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    // MARK: - 監視の設置

    private func watchDirectory() {
        guard directorySource == nil else { return }
        directorySource = makeSource(for: directory, mask: [.write, .rename, .delete]) {
            [weak self] events in
            guard let self else { return }
            // ディレクトリの中身が変わった。ファイルが差し替えられた可能性があるので
            // ファイル側の監視を張り直す。
            self.rewatchFile()
            if events.contains(.delete) || events.contains(.rename) {
                // ディレクトリ自体が消えた・付け替えられた。掴んでいる fd は使えない。
                self.log.debug("設定ディレクトリが差し替えられた。監視を張り直す")
                self.directorySource?.cancel()
                self.directorySource = nil
                self.schedule {
                    self.watchDirectory()
                    self.watchFile()
                    self.onChange?()
                }
                return
            }
            self.schedule { self.onChange?() }
        }
    }

    private func watchFile() {
        guard fileSource == nil, FileManager.default.fileExists(atPath: path) else { return }
        fileSource = makeSource(for: path, mask: [.write, .rename, .delete, .extend]) {
            [weak self] events in
            guard let self else { return }
            if events.contains(.delete) || events.contains(.rename) {
                self.rewatchFile()
            }
            self.schedule { self.onChange?() }
        }
    }

    private func rewatchFile() {
        fileSource?.cancel()
        fileSource = nil
        watchFile()
    }

    private func makeSource(
        for path: String,
        mask: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak source] in
            MainActor.assumeIsolated {
                handler(source?.data ?? [])
            }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        return source
    }

    /// 保存ソフトは1回の保存で複数回書き込む。まとめてから通知する。
    private func schedule(_ body: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                body()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
