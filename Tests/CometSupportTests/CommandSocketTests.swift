import Darwin
import Foundation
import Testing
@testable import CometSupport

/// 外から comet を動かす口（i3 の `i3-msg` 相当）。
///
/// **1接続1要求1応答で閉じる。** 状態を持たないので、途中で切れても後始末が要らない。
/// 応答の1バイト目が結果（`+` 成功 / `-` 失敗）を表す。
///
/// - Important: **受付はメインキューで動く。** ここでメインスレッドを塞いだまま
///   送ると accept が回らず、互いに待って止まる（実際に止めた）。
///   送る側は必ず `Task.detached` へ出して `await` する。
@Suite("コマンドの受付")
@MainActor
struct CommandSocketTests {

    /// テストのログは黙らせる。出すと全体の出力に紛れて読めなくなる。
    private func quietLog() -> Log {
        let log = Log()
        log.threshold = .off
        return log
    }

    private func temporaryPath() -> String {
        // ソケットのパスには 104 バイトの上限がある。短い場所に置く。
        "/tmp/comet-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    /// 送る側を別スレッドへ出す。`await` の間にメインキューが accept を回す。
    private func send(_ message: String, to path: String) async throws
        -> (succeeded: Bool, body: String)
    {
        try await Task.detached { try CommandClient.send(message, to: path) }.value
    }

    private func withServer(
        handler: @escaping CommandServer.Handler,
        body: (String) async throws -> Void
    ) async throws {
        let path = temporaryPath()
        let server = CommandServer(path: path, log: quietLog())
        try server.start(handler: handler)
        defer { server.stop() }
        try await body(path)
    }

    @Test("送った要求が届き、応答が返る")
    func roundTrip() async throws {
        try await withServer { request in .ok("受け取った: \(request)") } body: { path in
            let result = try await send("focus left", to: path)
            #expect(result.succeeded)
            #expect(result.body == "受け取った: focus left")
        }
    }

    // 解釈できない要求を「何も起きなかった」と区別できないと、スクリプトから使えない。
    @Test("失敗は成功と区別できる")
    func failureIsDistinguishable() async throws {
        try await withServer { _ in .failure("知らないコマンド") } body: { path in
            let result = try await send("nonsense", to: path)
            #expect(!result.succeeded)
            #expect(result.body == "知らないコマンド")
        }
    }

    @Test("前後の空白と改行は落とす")
    func trimsWhitespace() async throws {
        try await withServer { request in .ok(request) } body: { path in
            let result = try await send("  focus left \n", to: path)
            #expect(result.body == "focus left")
        }
    }

    @Test("空の要求は失敗として返す")
    func rejectsEmptyRequest() async throws {
        try await withServer { _ in .ok("呼ばれてはいけない") } body: { path in
            let result = try await send("   ", to: path)
            #expect(!result.succeeded)
        }
    }

    @Test("改行を含む応答もそのまま返る")
    func multilineResponse() async throws {
        try await withServer { _ in .ok("ws=1 state=focused\nws=2 state=hidden") } body: { path in
            let result = try await send("?workspaces", to: path)
            #expect(result.body.split(separator: "\n").count == 2)
        }
    }

    @Test("続けて何度でも送れる")
    func handlesRepeatedRequests() async throws {
        try await withServer { request in .ok(request.uppercased()) } body: { path in
            for index in 0..<5 {
                let result = try await send("a\(index)", to: path)
                #expect(result.body == "A\(index)")
            }
        }
    }

    @Test("動いていなければ理由の分かる失敗にする")
    func reportsNotRunning() async {
        await #expect(throws: (any Error).self) {
            try await send("focus left", to: "/tmp/comet-does-not-exist.sock")
        }
        let error = CommandSocket.SocketError.notRunning(path: "/tmp/x.sock")
        #expect(error.description.contains("動いていない"))
    }

    // 残っているソケットを消してから作る。消さないと bind が必ず失敗する。
    @Test("前回の残骸があっても始められる")
    func replacesStaleSocket() async throws {
        let path = temporaryPath()
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = CommandServer(path: path, log: quietLog())
        try server.start { _ in .ok("生きている") }
        defer { server.stop() }
        let result = try await send("ping", to: path)
        #expect(result.body == "生きている")
    }

    // 他の利用者から触らせない。ソケットの権限は umask 次第なので明示している。
    @Test("ソケットは自分だけが読み書きできる")
    func socketIsPrivate() async throws {
        try await withServer { _ in .ok("") } body: { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o600)
        }
    }

    @Test("止めるとソケットは残らない")
    func stopRemovesTheSocket() throws {
        let path = temporaryPath()
        let server = CommandServer(path: path, log: quietLog())
        try server.start { _ in .ok("") }
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path), "「応答しない口」を残さない")
    }

    @Test("長すぎるパスは理由を添えて弾く")
    func rejectsLongPath() {
        let long = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        #expect(throws: (any Error).self) { try CommandSocket.address(for: long) }
    }

    @Test("上限を超える要求は送る前に弾く")
    func rejectsHugeRequest() async {
        let huge = String(repeating: "x", count: CommandSocket.maximumMessageBytes + 1)
        await #expect(throws: (any Error).self) { try await send(huge, to: "/tmp/whatever.sock") }
    }
}
