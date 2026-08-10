import AppKit
import Foundation
import CometAccessibility
import CometConfig
import CometCore
import CometInput
import CometSupport

// Phase 1 の到達点:
//   「ウィンドウを開くと自動的にタイルされ、閉じると再配置される」
//
// main.swift のトップレベルコードは Swift 6 では @MainActor 隔離される。
// ここから同期 AX 呼び出しを行わないという規律は最後まで維持すること（設計書 §4.2）。

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

if options.printDefaultConfig {
    print(Configuration.defaultTOML)
    exit(0)
}

// MARK: - 設定

// 設定の誤りで起動を止めない。読めなかった項目は既定値に落ちて `problems` に理由が残る。
let configuration: Configuration
let configSource: ConfigLoader.Source
if options.ignoreConfig {
    configuration = ConfigLoader.builtIn()
    configSource = .builtIn
} else {
    (configuration, configSource) = ConfigLoader.load(
        path: options.configPath ?? ConfigLoader.defaultPath())
}

if let count = options.previewLayout {
    let area = LayoutPreview.primaryVisibleFrame()
    print("領域 (\(Int(area.minX)), \(Int(area.minY))) \(Int(area.width))x\(Int(area.height))  ウィンドウ \(count) 枚\n")
    print(
        LayoutPreview.render(
            count: count, area: area, gaps: configuration.gaps,
            strategy: configuration.insertionStrategy))
    exit(0)
}

// MARK: - ログ

let logLevel = options.resolvedLogLevel(configured: configuration.logLevel)
let log = Log.shared
log.threshold = logLevel
log.info("comet 起動 (log-level=\(logLevel.name), pid=\(getpid()))")

switch configSource {
case .file(let path):
    log.info("設定を読み込んだ: \(path)")
case .builtIn:
    log.info("設定ファイルが無いので組み込みの既定で起動する（--print-default-config で雛形を出せる）")
}

// 未対応コマンドは既定の設定にも並んでいるので、まとめて1行で伝える。
// 綴り間違いなど直せる問題は1件ずつ出す。
let unsupported = configuration.problems.filter {
    $0.kind == .unsupportedCommand || $0.kind == .unsupportedMode
}
for problem in configuration.problems where !unsupported.contains(problem) {
    log.warn("設定: \(problem)")
}
if !unsupported.isEmpty {
    log.info("設定: 未対応のため \(unsupported.count) 件のバインドを飛ばした（後続の Phase で実装する）")
    for problem in unsupported {
        log.debug("設定: \(problem)")
    }
}

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

// 利用者が --hotkey で指定したものは、押下をログに出すだけの動作確認用。
if !options.hotkeys.isEmpty {
    _ = registerHotkeys(specs: options.hotkeys, manager: hotkeyManager, log: log) { hotkey in
        Log.shared.info("押下: \(hotkey)")
    }
}

// MARK: - エンジン

// AeroSpace が動いていると互いのウィンドウ配置を上書きし合って発振する。
if !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty {
    log.warn(
        """
        AeroSpace が動作している。両方が動くとウィンドウ配置を奪い合って発振する。
        検証中は停止すること: osascript -e 'quit app "AeroSpace"'
        """)
}

if options.dryRun {
    log.info("dry-run: レイアウトを計算するがウィンドウは動かさない")
}

let engine = Engine(
    gaps: configuration.gaps, performance: configuration.performance,
    workspaceCount: configuration.workspaceCount,
    dryRun: options.dryRun, log: log)
engine.normalization = configuration.normalization
engine.insertionStrategy = configuration.insertionStrategy
engine.defaultOrientation = configuration.defaultOrientation
engine.windowRules = configuration.windowRules
engine.focusFollowsActivation = configuration.focusFollowsActivation
engine.start()

if engine.isTimingEnabled {
    log.info("計測が有効。ctrl-alt-shift-t で適用レイテンシを出力する")
}

// MARK: - 設定によるホットキー

// 複数コマンドの割り当ては**まとめて1回の再配置**にする。中間状態を適用しないことで
// 「ウィンドウ移動 + 切替」が1フレームで完了する（設計書 §9.5）。
var boundCount = 0
for binding in configuration.bindings {
    do {
        try hotkeyManager.register(binding.hotkey) { _ in
            for command in binding.commands {
                engine.execute(command)
            }
        }
        log.debug("登録: \(binding.spec) → \(binding.commands.count) コマンド")
        boundCount += 1
    } catch {
        // 他のウィンドウマネージャが同じキーを掴んでいると失敗する。
        // 1つ失敗しても残りは登録する。
        log.warn("\(binding.spec) を登録できなかった: \(error)")
    }
}
log.info("設定から \(boundCount)/\(configuration.bindings.count) 個のホットキーを登録した")

// MARK: - 制御用ホットキー

// 常駐プロセスなので、キーボードから止める手段と再配置の手段を用意しておく。
// 利用者指定のキーと衝突しうるので登録失敗は致命的としない。
@MainActor
func registerControlHotkey(_ spec: String, label: String, action: @escaping @MainActor () -> Void) {
    do {
        try hotkeyManager.register(KeySpec.parse(spec)) { _ in action() }
        log.info("\(label): \(spec)")
    } catch {
        log.warn("\(label) を登録できなかった: \(error)")
    }
}

// 終了前に AX で変えたものを元に戻す。
//
// 退避中のウィンドウを画面へ、無効化した AXEnhancedUserInterface を有効へ。
// 戻さずに終了すると、利用者からは「ウィンドウが消えた」ようにしか見えない。
// AX の適用は非同期なので少しだけ待つ。待ち時間には上限を置く
//（応答しないアプリで終われなくなるのを防ぐ）。
@MainActor
func terminateAfterRestoringWindows(reason: String) {
    Log.shared.info(reason)
    if engine.isTimingEnabled {
        for line in engine.timingReport {
            Log.shared.info("計測: \(line)")
        }
    }
    let restored = engine.prepareForTermination()
    guard restored > 0 else {
        NSApp.terminate(nil)
        return
    }
    Log.shared.info("退避していた \(restored) 枚を画面へ戻してから終了する")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        NSApp.terminate(nil)
    }
}

registerControlHotkey("ctrl-alt-shift-q", label: "終了") {
    terminateAfterRestoringWindows(reason: "終了ホットキーを受信した")
}

registerControlHotkey("ctrl-alt-shift-t", label: "計測の出力") {
    let lines = engine.timingReport
    guard !lines.isEmpty else {
        Log.shared.info(
            engine.isTimingEnabled
                ? "計測: まだ記録が無い" : "計測は無効（設定に [debug] timing = true を書く）")
        return
    }
    Log.shared.info("計測: 適用レイテンシ")
    for line in lines {
        Log.shared.info("  \(line)")
    }
}

registerControlHotkey("ctrl-alt-shift-r", label: "再配置") {
    // 全ワークスペースの状態も出す。配置がおかしいときに、レイアウト計算・
    // ツリーの組み方・所属ワークスペース・退避のどこがずれているのかを切り分けられる。
    Log.shared.info("再配置を要求された: \(engine.stateDescription)")
    engine.relayout()
}

// MARK: - 起動後に実行するコマンド

// ホットキーを押せない環境でもコマンドの経路を通せるようにする検証用の口。
// 走査が一巡してから流し、1つごとに状態を出して結果を追えるようにする。
if !options.commands.isEmpty {
    let specs = options.commands
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        MainActor.assumeIsolated {
            log.info("--run: \(specs.count) 件のコマンドを流す")
            log.info("--run: 開始時の状態 \(engine.stateDescription)")
            for (index, spec) in specs.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.3) {
                    MainActor.assumeIsolated {
                        do {
                            let command = try Command.parse(spec)
                            engine.execute(command)
                            log.info("--run: \(command) → \(engine.stateDescription)")
                        } catch {
                            log.error("--run: \"\(spec)\" を解釈できない: \(error)")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - シグナル

// SIGINT を DispatchSource で受けるには既定ハンドラを無効化する必要がある。
signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler {
    MainActor.assumeIsolated {
        terminateAfterRestoringWindows(reason: "SIGINT を受信した")
    }
}
interruptSource.resume()

// MARK: - 実行

log.info("起動完了。ホットキー \(hotkeyManager.registeredCount) 個。ウィンドウの走査を開始した。")
application.run()

// run() から戻るのは終了時のみ。ロックを最後まで生かしておくために参照する。
_ = instanceLock
