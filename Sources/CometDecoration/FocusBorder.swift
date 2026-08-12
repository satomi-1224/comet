import AppKit
import CoreGraphics
import CometCore
import CometSupport

/// フォーカス中のウィンドウに重ねる枠線。
///
/// macOS では他プロセスのウィンドウの枠そのものを変えられないので、**矩形にぴったり
/// 重なる透過ウィンドウを1枚置き、その縁だけを描く**（設計書 §8.2）。
///
/// - Important: **AX の適用完了を待たずに動かすこと。** 枠線は自プロセスのウィンドウなので
///   即座に動く。結果として「枠線が先に着地し、ウィンドウがそれに収まる」ように見え、
///   AX の遅延が視覚的に隠れる。
@MainActor
public final class FocusBorder {

    public var style: BorderStyle {
        didSet {
            guard style != oldValue else { return }
            applyStyle()
            // 有効・無効が切り替わったら今の表示に反映する。
            // **追跡中の ID は引き継ぐ。** 落とすと見えているかの確認が効かなくなる。
            if let frame = currentFrame {
                show(around: frame, windowID: trackedID)
            } else {
                hide()
            }
        }
    }

    private var window: NSWindow?
    /// 今表示している対象の矩形（AX 座標）。
    private var currentFrame: CGRect?
    /// 今囲んでいるウィンドウ。見えているかの確認に使う。
    private var trackedID: CGWindowID?
    /// 画面へ出しているか。`orderFront`/`orderOut` を無駄に呼ばないために持つ。
    private var isOrderedIn = false
    /// 対象が見えているかを見張るタイマー。**枠線を出している間だけ回す。**
    private var visibilityTimer: Timer?
    /// 画面の状態を取る手段。テストから差し替える。
    var screenSnapshot: @MainActor () -> WindowVisibility.Screen? = WindowVisibility.snapshot
    private let log: Log

    /// 対象が見えているかを確かめる間隔。
    ///
    /// **Mission Control には通知が無い**（`NSWorkspace` にも AX にも来ないことを実測）。
    /// 開いたことを知る手段が定期的な確認しかないため、枠線を出している間だけ回す。
    /// 1回あたり約 0.15ms なので、この間隔なら常駐コストはほぼ増えない。
    private static let visibilityInterval: TimeInterval = 0.2

    public init(style: BorderStyle = BorderStyle(), log: Log = .shared) {
        self.style = style
        self.log = log
    }

    /// 対象の矩形（AX 座標）を包む位置へ枠線を出す。
    ///
    /// - Parameter windowID: 囲む対象。渡すと**見えなくなったときに自動で引っ込む**
    ///   （Mission Control、別 Space のネイティブ全画面、Cmd+H、最小化）。
    public func show(around rect: CGRect, windowID: CGWindowID? = nil) {
        currentFrame = rect
        trackedID = windowID
        guard style.isEnabled, style.width > 0 else {
            orderOut()
            stopWatchingVisibility()
            return
        }

        let window = ensureWindow()
        // AX 座標（左上原点）→ AppKit 座標（左下原点）。
        // プライマリの高さはモニタ付け替えで変わるのでキャッシュしない。
        let outer = style.frame(around: rect)
        window.setFrame(
            Geometry.toAppKit(outer, primaryMaxY: MonitorManager.primaryMaxY), display: false)
        // 撮った画面の画素と突き合わせて検証できるように、実際に置いた位置を残す。
        // 「枠線が出ない」を追うときの最初の手がかりにもなる。
        log.trace(
            "枠線: (\(Int(outer.minX)), \(Int(outer.minY))) "
                + "\(Int(outer.width))x\(Int(outer.height))")

        refreshVisibility()
        startWatchingVisibility()
    }

    public func hide() {
        currentFrame = nil
        trackedID = nil
        stopWatchingVisibility()
        orderOut()
    }

    // MARK: - 見えているかの追従

    /// 対象が見えているかを確かめ、枠線の出し入れを合わせる。
    func refreshVisibility() {
        guard currentFrame != nil, style.isEnabled, style.width > 0 else {
            orderOut()
            return
        }
        if WindowVisibility.shouldShowBorder(for: trackedID, screen: screenSnapshot()) {
            orderIn()
        } else {
            // 見えていない間だけ引っ込める。`currentFrame` は保ったままなので、
            // 戻ってきたら同じ位置へそのまま出せる。
            orderOut()
        }
    }

    private func orderIn() {
        guard let window, !isOrderedIn else { return }
        window.orderFront(nil)
        isOrderedIn = true
    }

    private func orderOut() {
        guard isOrderedIn else { return }
        window?.orderOut(nil)
        isOrderedIn = false
        log.trace("枠線: 対象が見えないので引っ込めた")
    }

    private func startWatchingVisibility() {
        guard visibilityTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.visibilityInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibility() }
        }
        // 他のタイマーとまとめて起こしてよい。省電力のため幅を持たせる。
        timer.tolerance = Self.visibilityInterval / 2
        visibilityTimer = timer
    }

    private func stopWatchingVisibility() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }

    // MARK: - 内部

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let window = NSWindow(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 枠線はクリックを奪ってはならない。奪うと下のウィンドウが操作できなくなる。
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        // ネイティブ Space をまたいで居座り、Cmd+Tab の巡回には出ない。
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        window.contentView = view

        self.window = window
        applyStyle()
        return window
    }

    private func applyStyle() {
        guard let layer = window?.contentView?.layer else { return }
        layer.borderWidth = style.width
        layer.cornerRadius = style.radius
        layer.borderColor = style.focusedColor.cgColor
        layer.backgroundColor = CGColor.clear
    }
}

extension RGBAColor {
    /// 描画に渡す形へ。`CometCore` を AppKit から切り離しておくための橋渡し。
    ///
    /// - Important: **色空間を必ず sRGB で明示する。** `CGColor(red:green:blue:alpha:)`
    ///   は Generic RGB になり、設定に `#ff00ff` と書いた枠線が画面では
    ///   `#ff40ff` として描かれる（撮った画面の画素と突き合わせて実測）。
    ///   設定の綴りと出る色を一致させるために変換を挟まない形で作る。
    public var cgColor: CGColor {
        let components: [CGFloat] = [red, green, blue, alpha]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let color = CGColor(colorSpace: space, components: components)
        else {
            return CGColor(red: red, green: green, blue: blue, alpha: alpha)
        }
        return color
    }
}
