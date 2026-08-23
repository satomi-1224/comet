import AppKit
import CoreGraphics
import CometCore
import CometSupport

/// フォーカスしていないタイルの枠線。
///
/// i3 は**全てのウィンドウに枠を描き、色でフォーカスを表す**。macOS のウィンドウには
/// 影と角丸が付いているので既定では描かないが、分割の形を見せたいときに使う。
///
/// ## 作り方
///
/// ウィンドウ1枚につき透過ウィンドウを1枚重ねる。**使い回す**（枚数が変わるたびに
/// 作り直すと、切替のたびに画面がちらつく）。余ったぶんは隠して残し、次に増えたときに
/// また使う。
///
/// - Important: フォーカス中の1枚は ``FocusBorder`` が描く。ここでは描かない
///   （二重に描くと色が混ざる）。
@MainActor
public final class TileBorders {

    public var style: BorderStyle {
        didSet {
            guard style != oldValue else { return }
            for window in windows {
                apply(style, to: window)
            }
            refresh()
        }
    }

    /// 今囲んでいる矩形。ウィンドウ ID 順に並べる（並びが揺れると使い回しがずれる）。
    private var targets: [(id: CGWindowID, frame: CGRect)] = []
    private var windows: [NSWindow] = []
    private var visibilityTimer: Timer?
    /// 画面の状態を取る手段。テストから差し替える。
    var screenSnapshot: @MainActor () -> WindowVisibility.Screen? = WindowVisibility.snapshot
    private let log: Log

    /// 見えているかを確かめる間隔。``FocusBorder`` と揃える。
    private static let visibilityInterval: TimeInterval = 0.2

    public init(style: BorderStyle = BorderStyle(), log: Log = .shared) {
        self.style = style
        self.log = log
    }

    /// 囲む対象を伝える。**フォーカス中の1枚は渡さないこと。**
    public func update(_ frames: [(id: CGWindowID, frame: CGRect)]) {
        targets = frames.sorted { $0.id < $1.id }
        refresh()
    }

    public func hide() {
        targets = []
        refresh()
    }

    public func stop() {
        stopWatching()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        targets = []
    }

    /// 表示している枚数。検証用。
    public var visibleCount: Int {
        windows.filter(\.isVisible).count
    }

    // MARK: - 内部

    private func refresh() {
        guard style.drawsUnfocused, !targets.isEmpty else {
            stopWatching()
            for window in windows {
                window.orderOut(nil)
            }
            return
        }

        let screen = screenSnapshot()
        // 見えているものだけを対象にする。Mission Control 中は全部引っ込める。
        let shown = targets.filter { WindowVisibility.shouldShowBorder(for: $0.id, screen: screen) }

        while windows.count < shown.count {
            windows.append(makeWindow())
        }
        for (index, window) in windows.enumerated() {
            guard index < shown.count else {
                window.orderOut(nil)
                continue
            }
            let outer = style.frame(around: shown[index].frame)
            window.setFrame(
                Geometry.toAppKit(outer, primaryMaxY: MonitorManager.primaryMaxY), display: false)
            if !window.isVisible {
                window.orderFront(nil)
            }
        }
        log.trace("タイルの枠線: \(shown.count) 枚（保持 \(windows.count) 枚）")
        startWatching()
    }

    private func startWatching() {
        guard visibilityTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.visibilityInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = Self.visibilityInterval / 2
        visibilityTimer = timer
    }

    private func stopWatching() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 枠線はクリックを奪ってはならない。奪うと下のウィンドウが操作できなくなる。
        window.ignoresMouseEvents = true
        // **フォーカス枠より下に置く。** 同じ高さだと隣り合う枠の重なりで
        // どちらが手前になるかが実行ごとに変わる。
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        window.contentView = view
        apply(style, to: window)
        return window
    }

    private func apply(_ style: BorderStyle, to window: NSWindow) {
        guard let layer = window.contentView?.layer else { return }
        layer.borderWidth = style.width
        layer.cornerRadius = style.radius
        layer.borderColor = (style.unfocusedColor ?? .clear).cgColor
        layer.backgroundColor = CGColor.clear
    }
}
