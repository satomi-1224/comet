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
            if let frame = currentFrame {
                show(around: frame)
            } else {
                hide()
            }
        }
    }

    private var window: NSWindow?
    /// 今表示している対象の矩形（AX 座標）。
    private var currentFrame: CGRect?
    private let log: Log

    public init(style: BorderStyle = BorderStyle(), log: Log = .shared) {
        self.style = style
        self.log = log
    }

    /// 対象の矩形（AX 座標）を包む位置へ枠線を出す。
    public func show(around rect: CGRect) {
        currentFrame = rect
        guard style.isEnabled, style.width > 0 else {
            window?.orderOut(nil)
            return
        }

        let window = ensureWindow()
        // AX 座標（左上原点）→ AppKit 座標（左下原点）。
        // プライマリの高さはモニタ付け替えで変わるのでキャッシュしない。
        let outer = style.frame(around: rect)
        window.setFrame(
            Geometry.toAppKit(outer, primaryMaxY: MonitorManager.primaryMaxY), display: false)
        window.orderFront(nil)
        // 撮った画面の画素と突き合わせて検証できるように、実際に置いた位置を残す。
        // 「枠線が出ない」を追うときの最初の手がかりにもなる。
        log.trace(
            "枠線: (\(Int(outer.minX)), \(Int(outer.minY))) "
                + "\(Int(outer.width))x\(Int(outer.height))")
    }

    public func hide() {
        currentFrame = nil
        window?.orderOut(nil)
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
