import AppKit
import Foundation
import CometAccessibility
import CometConfig
import CometCore
import CometDecoration
import CometInput
import CometSupport
import ServiceManagement

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

// MARK: - 検証用のイベント送出

// **インスタンスロックより前に処理して終了する。** 常駐している comet へイベントを
// 送るための一発起動なので、ロックを取ると自分自身に弾かれる。
if let spec = options.emitKey {
    let parts = spec.split(separator: ":", maxSplits: 1)
    let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
    do {
        let hotkey = try KeySpec.parse(String(parts[0]))
        // 送出にも権限が要る。無いと post は黙って何もしないので、必ず確かめる。
        guard AXPermission.isTrusted() else {
            FileHandle.standardError.write(
                Data("送出側にアクセシビリティ権限が無い。イベントは届かない\n".utf8))
            exit(3)
        }
        let sent = SyntheticEvents.postKey(hotkey, count: count)
        print("送出: \(hotkey) を \(sent) 回（権限あり）")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("キー指定を解釈できない: \(error)\n".utf8))
        exit(2)
    }
}

if let spec = options.emitDrag {
    // "x,y:dx,dy"
    let halves = spec.split(separator: ":", maxSplits: 1)
    let from = halves.first.map { $0.split(separator: ",").compactMap { Double($0) } } ?? []
    let delta = halves.count > 1 ? halves[1].split(separator: ",").compactMap { Double($0) } : []
    guard from.count == 2, delta.count == 2 else {
        FileHandle.standardError.write(Data("--emit-drag は x,y:dx,dy の形で指定する\n".utf8))
        exit(2)
    }
    let start = CGPoint(x: from[0], y: from[1])
    let end = CGPoint(x: from[0] + delta[0], y: from[1] + delta[1])
    guard AXPermission.isTrusted() else {
        FileHandle.standardError.write(
            Data("送出側にアクセシビリティ権限が無い。イベントは届かない\n".utf8))
        exit(3)
    }
    SyntheticEvents.postDrag(from: start, to: end)
    print("送出: ドラッグ (\(Int(start.x)),\(Int(start.y))) → (\(Int(end.x)),\(Int(end.y)))")
    exit(0)
}

// MARK: - 設定

// 設定の誤りで起動を止めない。読めなかった項目は既定値に落ちて `problems` に理由が残る。
let configPath = options.configPath ?? ConfigLoader.defaultPath()
var configuration: Configuration
let configSource: ConfigLoader.Source
if options.ignoreConfig {
    configuration = ConfigLoader.builtIn()
    configSource = .builtIn
} else {
    (configuration, configSource) = ConfigLoader.load(path: configPath)
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
@MainActor
func reportConfigProblems(_ problems: [Problem]) {
    let unsupported = problems.filter {
        $0.kind == .unsupportedCommand || $0.kind == .unsupportedMode
            || $0.kind == .unsupportedOption
    }
    for problem in problems where !unsupported.contains(problem) {
        Log.shared.warn("設定: \(problem)")
    }
    guard !unsupported.isEmpty else { return }
    Log.shared.info("設定: 未対応のため \(unsupported.count) 件を飛ばした（後続の Phase で実装する）")
    for problem in unsupported {
        Log.shared.debug("設定: \(problem)")
    }
}

reportConfigProblems(configuration.problems)

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
engine.hiddenWindowStrategy = configuration.hiddenWindowStrategy

// MARK: - 内蔵UI
//
// Engine は表示を知らない（CometCore は AppKit に依存しない）。配線はここで行い、
// Engine はクロージャで合図だけを出す。
let decoration = DecorationController(
    border: configuration.border,
    indicator: configuration.indicator,
    hudDuration: configuration.hudDuration,
    workspaceCount: configuration.workspaceCount,
    log: log)
decoration.loadWallpapers(configuration.wallpapers)

// 内蔵UI は dry-run でも動かす。**他のアプリのウィンドウには一切触らない**ので安全で、
// 「枠線が目標位置を指す」ことがそのまま配置計算の目視確認になる。
engine.onFocusedFrameChanged = { [weak decoration] rect in
    decoration?.focusedFrameChanged(to: rect)
}
engine.onWorkspaceChanged = { [weak decoration] workspace in
    decoration?.workspaceChanged(to: workspace)
}

engine.start()

// 起動時のインジケータを合わせる（切替が起きるまで何も出ないのを避ける）。
decoration.workspaceChanged(to: engine.activeWorkspaceID)

if engine.isTimingEnabled {
    log.info("計測が有効。ctrl-alt-shift-t で適用レイテンシを出力する")
}

// MARK: - 設定によるホットキー

// 複数コマンドの割り当ては**まとめて1回の再配置**にする。中間状態を適用しないことで
// 「ウィンドウ移動 + 切替」が1フレームで完了する（設計書 §9.5）。
// 押しっぱなしでコマンドを繰り返すための仕掛け。
//
// **Carbon のホットキーはキー連射では繰り返し発火しない**（実測で 15 回送って 1 回）。
// `alt-ctrl-l` を押しっぱなしにしてリサイズを追従させるには自分で繰り返すしかない。
let repeater = HotkeyRepeater()
hotkeyManager.onRelease = { hotkey in
    repeater.end(hotkey)
}

/// 押しっぱなしで繰り返してよいコマンドか。
///
/// 繰り返すのは **`resize` だけ**にする。`move` や `workspace` が連射されると
/// ウィンドウが飛んでいって収拾がつかない。
@MainActor
func isRepeatable(_ commands: [Command]) -> Bool {
    !commands.isEmpty
        && commands.allSatisfy {
            if case .resize = $0 { return true }
            return false
        }
}

@MainActor
func registerConfiguredHotkeys(_ bindings: [Binding]) {
    var bound = 0
    for binding in bindings {
        let repeatable = isRepeatable(binding.commands)
        do {
            try hotkeyManager.register(binding.hotkey) { hotkey in
                for command in binding.commands {
                    engine.execute(command)
                }
                guard repeatable else { return }
                repeater.begin(hotkey) {
                    for command in binding.commands {
                        engine.execute(command)
                    }
                }
            }
            Log.shared.debug("登録: \(binding.spec) → \(binding.commands.count) コマンド")
            bound += 1
        } catch {
            // 他のウィンドウマネージャが同じキーを掴んでいると失敗する。
            // 1つ失敗しても残りは登録する。
            Log.shared.warn("\(binding.spec) を登録できなかった: \(error)")
        }
    }
    Log.shared.info("設定から \(bound)/\(bindings.count) 個のホットキーを登録した")
}

registerConfiguredHotkeys(configuration.bindings)

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
    repeater.stopAll()
    configWatcher.stop()
    decoration.stop()
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

@MainActor
func registerControlHotkeys() {
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
}

registerControlHotkeys()

// MARK: - 設定のホットリロード

// 起動時にしか組み立てられない値。再読込で変わっていたら知らせるために覚えておく。
let startupPerformance = configuration.performance
let startupStartAtLogin = configuration.startAtLogin

// 設定を読み直す。**ツリーの形は保つ。** 設定を触るたびに配置が崩れると常用できない。
//
// ワークスペースの数だけは動かさない。増減させるとウィンドウの所属が壊れるので、
// 変えたいときは再起動してもらう（起動時の値で固定する）。
@MainActor
func reloadConfiguration() {
    let (reloaded, source) = ConfigLoader.load(path: configPath)
    guard case .file(let path) = source else {
        Log.shared.warn("設定を読み直せなかった（\(configPath) が読めない）。現状の設定を使い続ける")
        reportConfigProblems(reloaded.problems)
        return
    }

    configuration = reloaded
    Log.shared.info("設定を読み直した: \(path)")
    reportConfigProblems(reloaded.problems)

    Log.shared.threshold = options.resolvedLogLevel(configured: reloaded.logLevel)

    engine.gaps = reloaded.gaps
    engine.normalization = reloaded.normalization
    engine.insertionStrategy = reloaded.insertionStrategy
    engine.defaultOrientation = reloaded.defaultOrientation
    engine.windowRules = reloaded.windowRules
    engine.focusFollowsActivation = reloaded.focusFollowsActivation
    engine.hiddenWindowStrategy = reloaded.hiddenWindowStrategy

    decoration.border.style = reloaded.border
    decoration.indicator.style = reloaded.indicator
    decoration.indicator.hudDuration = reloaded.hudDuration
    decoration.loadWallpapers(reloaded.wallpapers)

    // 起動時にしか組み立てられないものは、変わっていたら知らせる。
    // 黙って無視すると「設定したのに効かない」で詰まる。
    var needsRestart: [String] = []
    if reloaded.workspaceCount != engine.workspaceCount {
        needsRestart.append("[workspaces] count")
    }
    if reloaded.performance != startupPerformance {
        needsRestart.append("[performance] / [debug] timing")
    }
    if reloaded.startAtLogin != startupStartAtLogin {
        needsRestart.append("start-at-login")
    }
    if !needsRestart.isEmpty {
        Log.shared.warn(
            "次の項目は再起動しないと反映されない: \(needsRestart.joined(separator: ", "))")
    }

    // ホットキーは全解除して張り直す。差分を取るより確実。
    repeater.stopAll()
    hotkeyManager.unregisterAll()
    registerConfiguredHotkeys(reloaded.bindings)
    registerControlHotkeys()

    engine.configurationChanged()
}

engine.onReloadRequested = { reloadConfiguration() }

// 監視するのは**親ディレクトリ**。home-manager 管理下では config.toml は
// Nix ストアへのシンボリックリンクで、switch のときリンク先が差し替わる。
let configWatcher = ConfigWatcher(path: configPath, log: log)
configWatcher.onChange = { reloadConfiguration() }
if configWatcher.start() {
    log.info("設定の変更を監視: \(configWatcher.watchedDirectory)")
} else {
    log.debug("設定ディレクトリが無いので監視しない: \(configWatcher.watchedDirectory)")
}

// MARK: - ログイン起動

if configuration.startAtLogin {
    if Bundle.main.bundleIdentifier != nil {
        do {
            try SMAppService.mainApp.register()
            log.info("ログイン起動を有効にした")
        } catch {
            log.warn("ログイン起動を有効にできなかった: \(error)")
        }
    } else {
        // 素の実行ファイルには登録できない。build-app.sh で .app にしてから使う。
        log.warn("start-at-login はアプリバンドルでのみ有効（./scripts/build-app.sh を使う）")
    }
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
