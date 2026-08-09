import Foundation
import Testing

@testable import CometSupport

@Suite("SingleInstanceLock")
struct SingleInstanceLockTests {

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("comet-test-\(UUID().uuidString).lock")
            .path
    }

    @Test("初回の取得は成功する")
    func acquiresWhenFree() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock = try SingleInstanceLock(path: path)
        #expect(lock.path == path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    // flock はファイル記述に紐づくため、同一プロセス内でも別の open では衝突する。
    // これが二重起動の検知そのもの。
    @Test("保持中は再取得できない")
    func rejectsSecondAcquisition() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try SingleInstanceLock(path: path)
        #expect(throws: SingleInstanceLock.LockError.self) {
            _ = try SingleInstanceLock(path: path)
        }
        _ = first  // 解放されるとロックが外れるのでここまで生かす
    }

    @Test("解放後は再び取得できる")
    func releasesOnDeinit() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var lock: SingleInstanceLock? = try SingleInstanceLock(path: path)
        #expect(lock != nil)
        lock = nil

        // 解放後は取得できる。ここで投げたらロックが漏れている。
        let reacquired = try SingleInstanceLock(path: path)
        #expect(reacquired.path == path)
    }

    @Test("別のパスは互いに干渉しない")
    func distinctPathsAreIndependent() throws {
        let a = temporaryPath()
        let b = temporaryPath()
        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
        }

        let lockA = try SingleInstanceLock(path: a)
        let lockB = try SingleInstanceLock(path: b)
        #expect(lockA.path != lockB.path)
    }

    @Test("開けないパスは cannotOpen になる")
    func reportsUnopenablePath() {
        // ディレクトリが存在しないので open(2) が ENOENT で失敗する。
        let path = "/nonexistent-\(UUID().uuidString)/comet.lock"
        #expect(throws: SingleInstanceLock.LockError.self) {
            _ = try SingleInstanceLock(path: path)
        }
    }

    @Test("エラーの説明文は原因を特定できる情報を含む")
    func errorDescriptions() {
        let running = SingleInstanceLock.LockError.alreadyRunning(path: "/tmp/x.lock")
        #expect(running.description.contains("/tmp/x.lock"))
        #expect(running.description.contains("pgrep"))

        let cannotOpen = SingleInstanceLock.LockError.cannotOpen(path: "/tmp/y.lock", code: ENOENT)
        #expect(cannotOpen.description.contains("/tmp/y.lock"))
        // errno を数値だけでなく文言でも出す
        #expect(cannotOpen.description.lowercased().contains("no such file"))
    }

    @Test("既定のパスはバンドル ID を含み、親ディレクトリが作られる")
    func defaultPathIsUsable() {
        let path = SingleInstanceLock.defaultPath(bundleIdentifier: "local.comet.test")
        #expect(path.contains("local.comet.test"))
        #expect(path.hasSuffix("comet.lock"))

        let parent = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        try? FileManager.default.removeItem(atPath: parent)
    }
}
