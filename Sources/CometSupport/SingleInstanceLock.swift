import Darwin
import Foundation

/// 二重起動を防ぐためのプロセスロック。
///
/// comet が2つ同時に動くと、互いのホットキー登録とウィンドウ配置を奪い合う。
/// 特にホットキーは先に登録した側が勝つため、後から起動した側では
/// 「他プロセスに奪われている」という診断が出て、原因が AeroSpace なのか
/// 自分自身の残留インスタンスなのか区別できなくなる。
///
/// `flock(2)` はファイル記述に紐づくため、プロセスが SIGKILL されても
/// カーネルが自動的に解放する。ロックファイルの削除漏れを気にしなくてよい。
///
/// - Important: 取得したインスタンスはプロセスが生きている間ずっと保持すること。
///   解放されると `deinit` で記述子が閉じられ、ロックも外れる。
public final class SingleInstanceLock {

    public enum LockError: Error, CustomStringConvertible {
        case cannotOpen(path: String, code: Int32)
        case alreadyRunning(path: String)

        public var description: String {
            switch self {
            case .cannotOpen(let path, let code):
                "ロックファイルを開けない: \(path) (errno \(code): \(String(cString: strerror(code))))"
            case .alreadyRunning(let path):
                """
                既に別の comet が動作している（ロック: \(path)）。
                動作中のプロセス: pgrep -fl 'MacOS/comet'
                """
            }
        }
    }

    public let path: String
    private let descriptor: Int32

    /// 既定のロックファイルの位置。`~/Library/Caches/local.comet/comet.lock`。
    public static func defaultPath(bundleIdentifier: String = "local.comet") -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let base = caches ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("comet.lock").path
    }

    /// ロックを取得する。既に他プロセスが保持していれば ``LockError/alreadyRunning(path:)``。
    public init(path: String) throws {
        self.path = path

        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw LockError.cannotOpen(path: path, code: errno)
        }

        // LOCK_NB: 取得できなければ待たずに失敗する。
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw LockError.alreadyRunning(path: path)
            }
            throw LockError.cannotOpen(path: path, code: code)
        }

        self.descriptor = descriptor
    }

    deinit {
        // close(2) がファイル記述を解放し、flock も同時に外れる。
        close(descriptor)
    }
}
