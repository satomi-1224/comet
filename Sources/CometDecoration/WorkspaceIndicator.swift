import AppKit
import Foundation
import CometCore
import CometSupport

/// 今どのワークスペースを見ているかの表示。
///
/// メニューバー常駐（`NSStatusItem`）と、切替時に画面中央へ一瞬出す HUD の2通り。
/// 画面外退避方式では OS 側に切替の手掛かりが何も出ないので、これが唯一の合図になる。
@MainActor
public final class WorkspaceIndicator {

    public var style: IndicatorStyle {
        didSet {
            guard style != oldValue else { return }
            refresh()
        }
    }

    /// HUD を出しておく時間。
    public var hudDuration: TimeInterval

    private var statusItem: NSStatusItem?
    private var hud: NSWindow?
    private var hudDismissal: DispatchWorkItem?
    private var current: WorkspaceID = 1
    private var total: Int = 10
    private let log: Log

    public init(
        style: IndicatorStyle = .both, hudDuration: TimeInterval = 0.4, log: Log = .shared
    ) {
        self.style = style
        self.hudDuration = hudDuration
        self.log = log
    }

    /// 表示中のワークスペースが変わったことを伝える。
    public func update(to workspace: WorkspaceID, of total: Int) {
        let changed = workspace != current
        current = workspace
        self.total = total

        updateMenubar()
        // HUD は「切り替わった」ことを知らせるものなので、変化がなければ出さない。
        if changed, style.showsHUD {
            presentHUD()
        }
    }

    public func stop() {
        hudDismissal?.cancel()
        hudDismissal = nil
        hud?.orderOut(nil)
        hud = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - メニューバー

    private func refresh() {
        updateMenubar()
        if !style.showsHUD {
            hudDismissal?.cancel()
            hud?.orderOut(nil)
        }
    }

    private func updateMenubar() {
        guard style.showsMenubar else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            return
        }

        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.title = "\(current)"
        // 表示専用。押しても何も起きないのでクリックを受け付けない。
        item.button?.isEnabled = false
        item.button?.toolTip = "comet: ワークスペース \(current)/\(total)"

        // **置かれる場所を決めるのは OS 側**で、ウィンドウ一覧にも出てこない。
        // 撮った画面のどこを見れば良いか分かるように、横位置と幅を残しておく。
        //
        // 縦位置は残さない。status item のウィンドウは AppKit 座標でメニューバーの
        // 高さぶん上にあり（実測で画面の外を指す y になる）、作った直後は高さも 0 で
        // 返ってくる。上下の範囲は「メニューバーの高さ」として画面情報から決めるほうが確か。
        guard let frame = item.button?.window?.frame, frame.width > 0 else {
            log.debug("メニューバー: ワークスペース \(current)（位置は未確定）")
            return
        }
        log.debug(
            "メニューバー: ワークスペース \(current) x=\(Int(frame.minX)) 幅=\(Int(frame.width))")
    }

    // MARK: - HUD

    private func presentHUD() {
        let window = ensureHUD()
        if let label = window.contentView?.subviews.first as? NSTextField {
            label.stringValue = "\(current)"
        }

        // 連続切替では前の HUD を即座に差し替える。フェード中の重なりを避ける。
        hudDismissal?.cancel()
        window.alphaValue = 1
        centerHUD(window)
        window.orderFront(nil)
        let frame = window.frame
        log.debug(
            "HUD: ワークスペース \(current) "
                + "(\(Int(frame.minX)), \(Int(MonitorManager.primaryMaxY - frame.maxY))) "
                + "\(Int(frame.width))x\(Int(frame.height))")

        let dismissal = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.dismissHUD()
            }
        }
        hudDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + hudDuration, execute: dismissal)
    }

    private func dismissHUD() {
        guard let hud else { return }
        hudDismissal = nil

        // 「視差効果を減らす」が有効ならフェードを省く。
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hud.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            hud.animator().alphaValue = 0
        } completionHandler: { [weak hud] in
            hud?.orderOut(nil)
        }
    }

    private func centerHUD(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        window.setFrameOrigin(
            CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2))
    }

    private func ensureHUD() -> NSWindow {
        if let hud { return hud }

        let side: CGFloat = 120
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: side, height: side),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]

        let backdrop = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 20
        backdrop.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "\(current)")
        label.font = .monospacedDigitSystemFont(ofSize: 56, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        label.frame = CGRect(x: 0, y: (side - 70) / 2, width: side, height: 70)
        backdrop.addSubview(label)

        window.contentView = backdrop
        hud = window
        return window
    }
}
