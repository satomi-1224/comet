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

    /// ワークスペース番号 → 名前。書かれていない番号は番号だけを出す。
    public var names: [WorkspaceID: String] = [:] {
        didSet {
            guard names != oldValue else { return }
            refresh()
        }
    }

    private var statusItem: NSStatusItem?
    private var hud: NSWindow?
    private var hudDismissal: DispatchWorkItem?
    private var status = WorkspaceStatus(
        visible: [MonitorAssignment(monitor: 0, workspace: 1)], focused: 1, occupied: [], total: 10)
    private var current: WorkspaceID { status.focused }
    private var total: Int { status.total }
    private let log: Log
    /// メニューバーが常に隠れる設定か。**起動時に一度だけ読む。**
    ///
    /// 切替のたびに読んではいけない。`UserDefaults` の未キャッシュな読み出しは
    /// cfprefsd への同期問い合わせになり、**ワークスペース切替の経路に入って
    /// アプリを隠すのが目に見えて遅れた**（切替直後の画面がまだ前のワークスペースの
    /// ままになる。画素の検証で捕まえた）。
    private let menuBarIsAlwaysHidden = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    /// 警告を出したか。毎回出すと煩い。
    private var warnedAboutHiddenMenuBar = false

    public init(
        style: IndicatorStyle = .both, hudDuration: TimeInterval = 0.4, log: Log = .shared
    ) {
        self.style = style
        self.hudDuration = hudDuration
        self.log = log
    }

    /// ワークスペースの見え方が変わったことを伝える。
    public func update(_ status: WorkspaceStatus) {
        // HUD は「切り替わった」ことを知らせるもの。中身の増減で出しては煩い。
        let switched = status.focused != self.status.focused
            || status.visible != self.status.visible
        self.status = status

        updateMenubar()
        if switched, style.showsHUD {
            presentHUD()
        }
    }

    /// 今フォーカスしているモニタ。**HUD をどの画面に出すかを決める。**
    ///
    /// `NSScreen.main` はキーウィンドウのある画面なので、切り替えた側とは
    /// 別の画面を指すことがある（2画面で実際にそうなった）。
    private var focusedMonitor: MonitorID? { status.focusedMonitor }

    /// メニューバーに並べる1つ分。
    struct Segment: Equatable, Sendable {
        enum Emphasis: Equatable, Sendable {
            /// 今キー入力が効くワークスペース。
            case focused
            /// 別のモニタに映っている。
            case visible
            /// 映っていないがウィンドウが居る。
            case occupied
        }
        let workspace: WorkspaceID
        let text: String
        let emphasis: Emphasis
    }

    /// メニューバーに並べるもの。**i3 のバーと同じ考え方。**
    ///
    /// 出すのは「映っている」か「ウィンドウが居る」番号だけ。空の番号まで並べると、
    /// 押す手掛かりにならないうえ 10 個並んでメニューバーを埋める。
    ///
    /// 名前は**今いるワークスペースにだけ**添える。全部に添えると横に長くなり、
    /// 切り替えるたびに他の項目の位置が動いて読みにくい。
    nonisolated static func segments(
        _ status: WorkspaceStatus, names: [WorkspaceID: String] = [:]
    ) -> [Segment]
    {
        let visible = Set(status.visible.map(\.workspace))
        let listed = visible.union(status.occupied).sorted()
        return listed.map { id in
            let emphasis: Segment.Emphasis =
                id == status.focused ? .focused : (visible.contains(id) ? .visible : .occupied)
            var text = "\(id)"
            if id == status.focused, let name = names[id], !name.isEmpty {
                text += ":\(name)"
            }
            return Segment(workspace: id, text: text, emphasis: emphasis)
        }
    }

    /// ログと検証に使う平文。**画面に出るのは属性付きの文字列**（強調で区別する）。
    ///
    /// 平文では強調を表せないので、フォーカス中を `[]`、別モニタに映っているものを
    /// `()` で囲んで区別できるようにする。
    nonisolated static func plainTitle(_ segments: [Segment]) -> String {
        segments.map { segment in
            switch segment.emphasis {
            case .focused: "[\(segment.text)]"
            case .visible: "(\(segment.text))"
            case .occupied: segment.text
            }
        }.joined(separator: " ")
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

        // **メニューバーを自動的に隠す設定では、項目を置いても画面に出ない。**
        // 「インジケータを on にしたのに何も出ない」で詰まるので一度だけ知らせる。
        if menuBarIsAlwaysHidden, !warnedAboutHiddenMenuBar {
            warnedAboutHiddenMenuBar = true
            log.warn(
                "メニューバーを自動的に隠す設定のため、ワークスペース番号は常時表示されない。"
                    + "切替の合図は HUD を使う（[indicator] style = \"hud\"）")
        }

        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let segments = Self.segments(status, names: names)
        item.button?.attributedTitle = Self.attributedTitle(segments)
        // **`isEnabled = false` にしてはいけない。** 無効にしたボタンは
        // `attributedTitle` を**完全に透明で描く**ので、項目の幅は確保されるのに
        // 画面には何も出ない（macOS 15 で実測。素の `title` なら薄く描かれるが、
        // 強調で区別するには属性付きの文字列が要る）。
        // 押しても何も起きないのは target/action を持たせていないためで、無効化は要らない。
        item.button?.toolTip =
            "comet: ワークスペース \(current)/\(total)"
            + (names[current].map { "（\($0)）" } ?? "")
            + "\n太字=操作中 / 通常=別の画面に表示中 / 薄字=ウィンドウあり"

        // **置かれる場所を決めるのは OS 側**で、ウィンドウ一覧にも出てこない。
        // どこを見れば良いかの手掛かりとして横位置と幅を残しておく。
        //
        // - Important: **この座標を当てにして画面を撮ってはいけない。**
        //   2画面では実際に描かれている場所と食い違う値が返る
        //   （実測: 2台目のメニューバーに出ているのに x=3840 幅=29。その x は画面の外）。
        //   1画面でも食い違う（実測: ここが (0, -24) を返している間に、CGWindowList は
        //   同じ項目を x=1553 y=0 29x24＝メニューバーの正しい場所に見ていた）。
        //   **どこに出ているかを調べるときは CGWindowList を見る**
        //   （`comet-probe windows --any-layer`）。
        //   縦位置はさらに当てにならない（作った直後は高さ 0、y は画面の外を指す）。
        //   画素で確かめるときは位置を当てず、メニューバーの帯全体の差を見る
        //   （`scripts/verify.sh` の `capture_menubars`）。
        guard let frame = item.button?.window?.frame, frame.width > 0 else {
            log.debug("メニューバー: \(Self.plainTitle(segments))（位置は未確定）")
            return
        }
        log.debug(
            "メニューバー: \(Self.plainTitle(segments)) "
                + "x=\(Int(frame.minX)) 幅=\(Int(frame.width))")
    }

    /// 強調で区別した表示。
    ///
    /// **記号で区別しない。** `[1] (2) 5` のように括弧を並べるとメニューバーが
    /// 賑やかになり、番号そのものが読みにくい。太さと濃さで差を付ける。
    private static func attributedTitle(_ segments: [Segment]) -> NSAttributedString {
        let size = NSFont.systemFontSize
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " "))
            }
            let attributes: [NSAttributedString.Key: Any]
            switch segment.emphasis {
            case .focused:
                attributes = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ]
            case .visible:
                attributes = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
            case .occupied:
                attributes = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }

    // MARK: - HUD

    private func presentHUD() {
        let window = ensureHUD()
        numberLabel?.stringValue = "\(current)"
        // 名前が付いていれば番号の下に添える。番号だけでは「どこへ行ったか」は
        // 分かっても「そこが何の場所か」が分からない。
        let name = names[current] ?? ""
        nameLabel?.stringValue = name
        nameLabel?.isHidden = name.isEmpty
        // 名前があるぶん数字を上へ寄せる。中央に置いたままだと名前と重なる。
        layoutHUDLabels(hasName: !name.isEmpty)

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
        guard let screen = hudScreen() else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        window.setFrameOrigin(
            CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2))
    }

    /// HUD を出す画面。切り替わったモニタを優先する。
    private func hudScreen() -> NSScreen? {
        if let focusedMonitor {
            let match = NSScreen.screens.first { screen in
                guard
                    let number = screen.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else { return false }
                return MonitorID(number.uint32Value) == focusedMonitor
            }
            if let match { return match }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// HUD の一辺。数字と名前が収まる大きさ。
    private static let hudSide: CGFloat = 120

    private func ensureHUD() -> NSWindow {
        if let hud { return hud }

        let side = Self.hudSide
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

        let number = NSTextField(labelWithString: "\(current)")
        number.font = .monospacedDigitSystemFont(ofSize: 56, weight: .semibold)
        number.alignment = .center
        number.textColor = .labelColor
        backdrop.addSubview(number)
        numberLabel = number

        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 15, weight: .medium)
        name.alignment = .center
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.isHidden = true
        backdrop.addSubview(name)
        nameLabel = name

        window.contentView = backdrop
        hud = window
        layoutHUDLabels(hasName: false)
        return window
    }

    /// HUD の中身を並べる。名前があるかどうかで縦位置が変わる。
    private func layoutHUDLabels(hasName: Bool) {
        let side = Self.hudSide
        let numberHeight: CGFloat = 70
        if hasName {
            numberLabel?.frame = CGRect(
                x: 0, y: (side - numberHeight) / 2 + 12, width: side, height: numberHeight)
            nameLabel?.frame = CGRect(x: 8, y: 22, width: side - 16, height: 20)
        } else {
            numberLabel?.frame = CGRect(
                x: 0, y: (side - numberHeight) / 2, width: side, height: numberHeight)
        }
    }

    private var numberLabel: NSTextField?
    private var nameLabel: NSTextField?
}
