import AppKit
import Foundation
import CometAccessibility
import CometInput
import CometSupport

// Phase 0 の到達点:
//   「ホットキーを押すとログが出る。アクセシビリティ権限が正しく取得できている」
//
// main.swift のトップレベルコードは Swift 6 では @MainActor 隔離される。
// ここから同期 AX 呼び出しを行わないという規律は Phase 1 以降も維持すること
// （設計書 §4.2）。

// MARK: - ヘルパー

@MainActor
func fail(_ message: String, code: Int32 = 1) -> Never {
    // `open` で起動すると stderr はどこにも出ないため、必ず統一ログにも残す。
    // --log-level off でも致命的な失敗は握り潰さない。
    if Log.shared.threshold > .error {
        Log.shared.threshold = .error
    }
    Log.shared.error(message)
    exit(code)
}

@MainActor
func registerHotkeys(
    specs: [String],
    manager: HotkeyManager,
    log: Log,
    handler: @escaping HotkeyManager.Handler
) -> Int {
    var registered = 0
    for spec in specs {
        do {
            let hotkey = try KeySpec.parse(spec)
            try manager.register(hotkey, handler: handler)
            log.info("登録: \(spec) → \(hotkey)")
            registered += 1
        } catch {
            log.error("\(spec) を登録できなかった: \(error)")
        }
    }
    return registered
}

// MARK: - 引数

let arguments = Array(CommandLine.arguments.dropFirst())

let options: LaunchOptions
do {
    options = try LaunchOptions.parse(arguments)
} catch {
    FileHandle.standardError.write(
        Data("エラー: \(error)\n\n\(LaunchOptions.usage)\n".utf8))
    exit(2)
}

if options.showHelp {
    print(LaunchOptions.usage)
    exit(0)
}

if options.printKeys {
    print(KeySpec.knownKeyNames.joined(separator: "\n"))
    exit(0)
}

// MARK: - ログ

let log = Log.shared
log.threshold = options.logLevel
log.info("comet 起動 (log-level=\(options.logLevel.name), pid=\(getpid()))")

// 非公開シンボルの解決状況を起動時に記録しておく。
// OS アップデートで消えた場合、ここが最初の手がかりになる（設計書 §12.2）。
if AXPrivate.isGetWindowAvailable {
    log.debug("_AXUIElementGetWindow を解決した")
} else {
    log.warn(
        """
        _AXUIElementGetWindow を解決できなかった。
        この OS ではウィンドウ ID を AX 要素から取得できない。
        設計書 §12.2 のフォールバックが必要。
        """)
}

// MARK: - 二重起動の防止

// 権限確認より先に行う。2つ目のインスタンスをホットキー登録まで進ませると、
// 「他プロセスに奪われている」という診断が出て、原因が AeroSpace なのか
// 自分自身の残留インスタンスなのか区別できなくなる。
//
// このロックはプロセス終了まで保持し続ける必要があるためトップレベルで束縛する。
let instanceLock: SingleInstanceLock
do {
    instanceLock = try SingleInstanceLock(path: SingleInstanceLock.defaultPath())
    log.debug("インスタンスロックを取得: \(instanceLock.path)")
} catch {
    fail("\(error)")
}

// MARK: - アクセシビリティ権限

if !AXPermission.isTrusted() {
    log.warn("アクセシビリティ権限がない")
    let granted = AXPermission.waitUntilTrusted(timeout: 120) {
        log.info(
            """
            「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で comet を許可してください。
            最大 120 秒待機します。
            """)
    }
    guard granted else {
        fail("アクセシビリティ権限が得られなかった")
    }
    log.info("アクセシビリティ権限を取得した")
} else {
    log.info("アクセシビリティ権限あり")
}

// MARK: - NSApplication

// メニューバーにも Dock にも出さない常駐プロセスとして動かす。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// MARK: - ホットキー

let hotkeyManager = HotkeyManager(log: log)
do {
    try hotkeyManager.start()
} catch {
    fail("\(error)")
}

// AeroSpace が alt-* を掴んでいる間は衝突するため、既定は ctrl-alt-shift-* にしてある。
let defaultSpecs = [
    "ctrl-alt-shift-h", "ctrl-alt-shift-j", "ctrl-alt-shift-k", "ctrl-alt-shift-l",
]
let specs = options.hotkeys.isEmpty ? defaultSpecs : options.hotkeys

if options.hotkeys.isEmpty {
    log.info("--hotkey の指定がないため既定のバインドを使う")
}

let registeredCount = registerHotkeys(specs: specs, manager: hotkeyManager, log: log) { hotkey in
    Log.shared.info("押下: \(hotkey)")
}

guard registeredCount > 0 else {
    fail(
        """
        ホットキーを1つも登録できなかった。
        他のプロセス（AeroSpace / Hammerspoon / Raycast など）が同じキーを掴んでいる可能性がある。
        """)
}

// 常駐プロセスなので、キーボードから止める手段を用意しておく。
// 利用者指定のキーと衝突しうるので失敗は致命的としない。
let quitSpec = "ctrl-alt-shift-q"
if let quitHotkey = try? KeySpec.parse(quitSpec) {
    do {
        try hotkeyManager.register(quitHotkey) { _ in
            Log.shared.info("終了ホットキーを受信した")
            NSApp.terminate(nil)
        }
        log.info("終了ホットキー: \(quitSpec)")
    } catch {
        log.warn("終了ホットキーを登録できなかった: \(error)")
    }
}

// MARK: - シグナル

// SIGINT を DispatchSource で受けるには既定ハンドラを無効化する必要がある。
signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler {
    MainActor.assumeIsolated {
        Log.shared.info("SIGINT を受信した")
        NSApp.terminate(nil)
    }
}
interruptSource.resume()

// MARK: - 実行

log.info("\(hotkeyManager.registeredCount) 個のホットキーを登録した。押すとログが出る。")
application.run()

// run() から戻るのは終了時のみ。ロックを最後まで生かしておくために参照する。
_ = instanceLock
