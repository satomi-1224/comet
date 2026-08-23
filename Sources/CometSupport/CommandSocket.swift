import Darwin
import Dispatch
import Foundation

/// 常駐している comet へコマンドを届けるための口（i3 の `i3-msg` 相当）。
///
/// ## なぜ要るのか
///
/// ホットキーだけが入口だと、**外から comet を動かす手段が無い**。
///
/// - 状態バー（sketchybar など）に「今どのワークスペースか」を出せない
/// - シェルスクリプトから「ウィンドウを整えてから何かする」が書けない
/// - 検証で「キーを合成する」しかなくなる（送出側にも権限が要り、
///   他のアプリのキーバインドと衝突する）
///
/// i3 では `i3-msg` がこの役目を持っており、周辺のツールはほぼ全てこれに乗っている。
///
/// ## 形
///
/// UNIX ドメインソケット。**1接続1要求1応答で閉じる。** 状態を持たないので、
/// 途中で切れても後始末が要らない。
///
/// 応答の1バイト目が結果を表す。`+` なら成功、`-` なら失敗。
/// 解釈できない要求を「何も起きなかった」と区別できないと、スクリプトから使えない。
///
/// - Note: TCP は使わない。ポートを開けると同じ機械の他の利用者から届いてしまう。
///   UNIX ドメインソケットならファイルの権限（0600）でそれを止められる。
public enum CommandSocket {

    /// 応答の先頭に付ける印。
    public enum Result: Sendable, Equatable {
        case ok(String)
        case failure(String)

        var wireFormat: String {
            switch self {
            case .ok(let body): "+\(body)"
            case .failure(let body): "-\(body)"
            }
        }
    }

    /// 要求と応答の上限。**上限を置かないと、壊れた相手にメモリを食わされる。**
    static let maximumMessageBytes = 64 * 1024

    /// 送る側が待つ上限。
    ///
    /// **待ち続けさせてはいけない。** 常駐側が何かで詰まっているとき、
    /// `comet --send` を呼んだスクリプトが永久に返らなくなる。
    /// 応答は数十バイトなので、この長さで足りないのは相手が詰まっている場合だけ。
    static let clientTimeout = timeval(tv_sec: 2, tv_usec: 0)

    /// 既定のソケットの位置。ロックファイルと同じディレクトリに置く。
    public static func defaultPath(bundleIdentifier: String = "local.comet") -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let base = caches ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("comet.sock").path
    }

    public enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(path: String, limit: Int)
        case cannotCreate(code: Int32)
        case cannotBind(path: String, code: Int32)
        case cannotListen(code: Int32)
        case cannotConnect(path: String, code: Int32)
        case notRunning(path: String)
        case tooLarge(bytes: Int)

        public var description: String {
            switch self {
            case .pathTooLong(let path, let limit):
                "ソケットのパスが長すぎる（\(limit) バイトまで）: \(path)"
            case .cannotCreate(let code):
                "ソケットを作れない (errno \(code): \(String(cString: strerror(code))))"
            case .cannotBind(let path, let code):
                "ソケットを配置できない: \(path) (errno \(code): \(String(cString: strerror(code))))"
            case .cannotListen(let code):
                "ソケットを待ち受けられない (errno \(code): \(String(cString: strerror(code))))"
            case .cannotConnect(let path, let code):
                "comet に接続できない: \(path) "
                    + "(errno \(code): \(String(cString: strerror(code))))"
            case .notRunning(let path):
                """
                comet が動いていない（ソケットが無い: \(path)）。
                先に comet を起動する。
                """
            case .tooLarge(let bytes):
                "メッセージが大きすぎる（\(bytes) バイト）"
            }
        }
    }

    /// `sockaddr_un` を組み立てる。パスの長さの上限はここで確かめる。
    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // 終端の 0 を置く余地を残す。
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard bytes.count <= limit else {
            throw SocketError.pathTooLong(path: path, limit: limit)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}

/// 要求を受ける側。**常駐している comet が持つ。**
///
/// 受け取りも応答もメインキューで行う。``Engine`` はメインアクター上でしか
/// 触れないため、別のキューで受けると渡す先が無い。1要求は数十バイトなので
/// メインキューを塞がない。
@MainActor
public final class CommandServer {

    /// 要求1件を処理する。**解釈も実行も呼び出し側の仕事。**
    public typealias Handler = @MainActor (String) -> CommandSocket.Result

    public let path: String
    private let log: Log
    private var descriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var handler: Handler?

    public init(path: String = CommandSocket.defaultPath(), log: Log = .shared) {
        self.path = path
        self.log = log
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// 待ち受けを始める。
    ///
    /// - Important: **必ずインスタンスロックを取ったあとで呼ぶこと。**
    ///   残っているソケットを消してから作るので、二重起動中に呼ぶと
    ///   動いている側の口を奪う。
    public func start(handler: @escaping Handler) throws {
        guard descriptor < 0 else { return }
        self.handler = handler

        let address = try CommandSocket.address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CommandSocket.SocketError.cannotCreate(code: errno) }

        // 前回の残骸を消す。**bind は既にあるパスには失敗する。**
        // ロックを取ったあとなので、消して良いのは自分のものだけ。
        unlink(path)

        var bound = address
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard status == 0 else {
            let code = errno
            close(fd)
            throw CommandSocket.SocketError.cannotBind(path: path, code: code)
        }
        // **他の利用者から触らせない。** ソケットの権限は umask 次第なので明示する。
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw CommandSocket.SocketError.cannotListen(code: code)
        }

        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptOne() }
        }
        source.resume()
        acceptSource = source
        log.info("コマンドの受付を開始した: \(path)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        // **消しておく。** 残すと次の起動で「動いているのに応答しない」口に見える。
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        guard let request = Self.readMessage(from: client) else { return }
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Self.write(CommandSocket.Result.failure("要求が空").wireFormat, to: client)
            return
        }
        let result = handler?(trimmed) ?? .failure("受け付けの配線がされていない")
        Self.write(result.wireFormat, to: client)
    }

    /// 相手が書き終える（`shutdown` するか閉じる）まで読む。
    ///
    /// 送る側（`--send` の一発起動）からも使うので隔離しない。
    nonisolated static func readMessage(from descriptor: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= CommandSocket.maximumMessageBytes {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                continue
            }
            // 0 は相手が書き終えた。負は失敗（割り込みだけ続ける）。
            // **待ち時間切れ（EAGAIN）では続けない。** 続けると上限が意味を失う。
            if count < 0, errno == EINTR { continue }
            break
        }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func write(_ text: String, to descriptor: Int32) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { pointer in
                Darwin.write(descriptor, pointer.baseAddress, pointer.count)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            break
        }
    }
}

/// 要求を送る側。**`comet --send` の一発起動が使う。**
public enum CommandClient {

    /// 送って応答を待つ。
    ///
    /// - Returns: 成功したかと、応答の本文。
    public static func send(_ message: String, to path: String = CommandSocket.defaultPath())
        throws -> (succeeded: Bool, body: String)
    {
        guard message.utf8.count <= CommandSocket.maximumMessageBytes else {
            throw CommandSocket.SocketError.tooLarge(bytes: message.utf8.count)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw CommandSocket.SocketError.notRunning(path: path)
        }

        var address = try CommandSocket.address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CommandSocket.SocketError.cannotCreate(code: errno) }
        defer { close(fd) }

        var timeout = CommandSocket.clientTimeout
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard status == 0 else {
            throw CommandSocket.SocketError.cannotConnect(path: path, code: errno)
        }

        CommandServer.write(message, to: fd)
        // **書き終わりを伝える。** 伝えないと相手が読み続けて互いに待つ。
        shutdown(fd, SHUT_WR)

        let response = CommandServer.readMessage(from: fd) ?? ""
        guard let marker = response.first else { return (false, "応答が無い") }
        let body = String(response.dropFirst())
        return (marker == "+", body)
    }
}
