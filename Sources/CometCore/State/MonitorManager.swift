import AppKit
import CoreGraphics
import Foundation
import CometSupport

/// ディスプレイ構成の把握。
///
/// 1画面運用でも必須。外部モニタを付け替えると解像度・union 矩形・プライマリの高さが
/// すべて変わるため、変換に使う値を更新しないとウィンドウが画面外へ飛ぶ。
@MainActor
public final class MonitorManager {

    public struct Monitor: Equatable, Sendable {
        public let id: CGDirectDisplayID
        /// AX 座標系でのモニタ全体。
        public let frame: CGRect
        /// AX 座標系での作業領域（メニューバーと Dock を除く）。
        public let visibleFrame: CGRect
        /// プライマリ（座標原点を含むディスプレイ）か。
        public let isPrimary: Bool
        public let scale: CGFloat
    }

    public private(set) var monitors: [Monitor] = []
    public var onChange: (@MainActor () -> Void)?

    /// 解像度変更中は通知が連続して飛ぶのでまとめる。
    private var pendingRefresh: DispatchWorkItem?
    private let debounce: TimeInterval
    private let log: Log

    public init(debounce: TimeInterval = 0.2, log: Log = .shared) {
        self.debounce = debounce
        self.log = log
    }

    /// AppKit 座標系におけるプライマリの上端。座標変換の基準になる。
    ///
    /// - Important: **キャッシュしないこと。** モニタ付け替えで変わる。
    public static var primaryMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    public var primary: Monitor? {
        monitors.first(where: \.isPrimary) ?? monitors.first
    }

    /// その矩形を持っているモニタ。**中心が乗っているモニタ**で決める。
    ///
    /// 面積比で決めると、2画面に跨がるウィンドウが境界付近で行き来して落ち着かない。
    /// どのモニタにも乗っていなければ `nil`（画面の隅へ退避したウィンドウがこれになる）。
    public nonisolated static func owner(of rect: CGRect, among monitors: [Monitor]) -> Monitor? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return monitors.first { $0.frame.contains(center) }
    }

    /// メインディスプレイの外（サブディスプレイの上）にあるか。
    ///
    /// **判断できないときは `false`。** 「分からない」を「サブにある」と扱うと、
    /// 非表示ワークスペースのために画面の隅へ追い込んだウィンドウ（中心がどのモニタからも
    /// 外れる）まで管理対象から外れ、**二度と画面へ戻せなくなる。**
    public nonisolated static func isOutsideMain(_ rect: CGRect, monitors: [Monitor]) -> Bool {
        guard monitors.count > 1, let owner = owner(of: rect, among: monitors) else { return false }
        return !owner.isPrimary
    }

    public func start() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
            }
        }
    }

    public func refresh() {
        let maxY = Self.primaryMaxY
        let screens = NSScreen.screens

        monitors = screens.enumerated().map { index, screen in
            let number =
                screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return Monitor(
                id: number?.uint32Value ?? CGDirectDisplayID(index),
                frame: Geometry.toAX(screen.frame, primaryMaxY: maxY),
                visibleFrame: Geometry.toAX(screen.visibleFrame, primaryMaxY: maxY),
                isPrimary: index == 0,
                scale: screen.backingScaleFactor)
        }

        log.debug(
            "モニタ構成: "
                + monitors.map { "#\($0.id) \(Int($0.frame.width))x\(Int($0.frame.height))@\($0.scale)x" }
                .joined(separator: ", "))
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.onChange?()
            }
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
