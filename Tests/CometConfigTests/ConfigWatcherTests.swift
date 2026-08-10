import Foundation
import Testing
import CometSupport

@testable import CometConfig

/// 設定ファイルの監視。
///
/// **ファイルと親ディレクトリの両方を見ないと取りこぼす。** 上書き保存はファイルへの
/// 書き込みとして、rename での差し替え（vim や home-manager）はディレクトリへの
/// 書き込みとして届く。両方を実際のファイル操作で確かめる。
@MainActor
@Suite("ConfigWatcher")
struct ConfigWatcherTests {

    private func quietLog() -> Log {
        let log = Log()
        log.threshold = .off
        return log
    }

    /// テストごとに独立した一時ディレクトリ。
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("comet-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 条件が満たされるまで待つ。ファイルシステムの通知は即座には届かない。
    private func wait(
        upTo seconds: Double = 3, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - 監視の開始

    @Test("ディレクトリが無ければ監視できない")
    func missingDirectoryCannotBeWatched() {
        let watcher = ConfigWatcher(path: "/nonexistent/comet/config.toml", log: quietLog())
        #expect(!watcher.start())
        #expect(!watcher.isWatching)
    }

    @Test("ファイルが無くてもディレクトリは監視する")
    func watchesDirectoryWithoutFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = ConfigWatcher(
            path: directory.appendingPathComponent("config.toml").path, log: quietLog())
        defer { watcher.stop() }

        #expect(watcher.start(), "あとから置かれるファイルに気づけるようにする")
        #expect(watcher.isWatching)
        #expect(!watcher.isWatchingFile)
    }

    @Test("監視するディレクトリはファイルの親")
    func watchedDirectoryIsTheParent() {
        let watcher = ConfigWatcher(path: "/a/b/config.toml", log: quietLog())
        #expect(watcher.watchedDirectory == "/a/b")
    }

    @Test("stop すると監視が外れる")
    func stopReleasesWatch() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = ConfigWatcher(
            path: directory.appendingPathComponent("config.toml").path, log: quietLog())
        watcher.start()
        watcher.stop()
        #expect(!watcher.isWatching)
    }

    // MARK: - 変更の検知

    // エディタが内容だけを書き換える形。ディレクトリだけを見ていると取りこぼす。
    @Test("上書き保存を検知する")
    func detectsInPlaceWrite() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        try "a = 1".write(to: file, atomically: false, encoding: .utf8)

        let watcher = ConfigWatcher(path: file.path, debounce: 0.05, log: quietLog())
        defer { watcher.stop() }
        var changes = 0
        watcher.onChange = { changes += 1 }
        #expect(watcher.start())
        #expect(watcher.isWatchingFile)

        try "a = 2".write(to: file, atomically: false, encoding: .utf8)
        #expect(await wait { changes > 0 }, "変更に気づかなかった")
    }

    // vim の既定や home-manager のシンボリックリンク張り替えはこの形。
    @Test("rename での差し替えを検知する")
    func detectsRename() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        try "a = 1".write(to: file, atomically: false, encoding: .utf8)

        let watcher = ConfigWatcher(path: file.path, debounce: 0.05, log: quietLog())
        defer { watcher.stop() }
        var changes = 0
        watcher.onChange = { changes += 1 }
        watcher.start()

        let temporary = directory.appendingPathComponent("tmp.toml")
        try "a = 2".write(to: temporary, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)

        #expect(await wait { changes > 0 }, "差し替えに気づかなかった")
    }

    // 差し替えられると inode が変わる。張り直さないと2回目以降を取りこぼす。
    @Test("差し替えのあとも監視が続く")
    func keepsWatchingAfterReplacement() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        try "a = 1".write(to: file, atomically: false, encoding: .utf8)

        let watcher = ConfigWatcher(path: file.path, debounce: 0.05, log: quietLog())
        defer { watcher.stop() }
        var changes = 0
        watcher.onChange = { changes += 1 }
        watcher.start()

        // 1回目: rename で差し替え
        let temporary = directory.appendingPathComponent("tmp.toml")
        try "a = 2".write(to: temporary, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        #expect(await wait { changes >= 1 })

        // 2回目: 新しい inode に対する上書き保存
        let first = changes
        try "a = 3".write(to: file, atomically: false, encoding: .utf8)
        #expect(await wait { changes > first }, "張り直せていないと2回目を取りこぼす")
    }

    // 保存ソフトは1回の保存で複数回書き込む。まとめないと再読込が何度も走る。
    @Test("連続した書き込みはまとめられる")
    func coalescesRapidWrites() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        try "a = 1".write(to: file, atomically: false, encoding: .utf8)

        let watcher = ConfigWatcher(path: file.path, debounce: 0.3, log: quietLog())
        defer { watcher.stop() }
        var changes = 0
        watcher.onChange = { changes += 1 }
        watcher.start()

        for value in 2...6 {
            try "a = \(value)".write(to: file, atomically: false, encoding: .utf8)
        }
        #expect(await wait { changes > 0 })
        // まとめの窓を過ぎても増えないこと。
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(changes == 1, "\(changes) 回通知された")
    }
}
