import Foundation

/// 速さと堅牢性のつまみ（設計書 §9.2 の `[performance]`）。
public struct PerformanceOptions: Sendable, Equatable {

    /// AX メッセージングのタイムアウト。
    ///
    /// 既定の 6 秒だと、ハングしたアプリが1つあるだけでそのキューが 6 秒止まる。
    /// 短くして「そのアプリだけ諦める」ようにする。
    public var axTimeout: TimeInterval

    /// 目標矩形を流し込む間隔。8ms ≒ 120Hz（ProMotion のフレーム間隔）。
    public var applyInterval: TimeInterval

    /// 目標とずれた場合に投げ直す回数の上限。
    public var maxCorrections: Int

    /// ウィンドウ操作を遅くする `AXEnhancedUserInterface` を無効化するか。
    public var disablesEnhancedUserInterface: Bool

    /// 適用のレイテンシをアプリ別に集計するか（設計書 §11.3）。
    public var isTimingEnabled: Bool

    /// ホットキーを押しっぱなしにしてから繰り返しが始まるまで。
    ///
    /// **Carbon のホットキーはキー連射では繰り返し発火しない**ので、離されるまで
    /// comet が自分で繰り返す（`HotkeyRepeater`）。その待ち時間。
    public var repeatDelay: TimeInterval

    /// 繰り返しの間隔。0.03 ≒ 30Hz。
    public var repeatInterval: TimeInterval

    public init(
        axTimeout: TimeInterval = 0.1,
        applyInterval: TimeInterval = 0.008,
        maxCorrections: Int = 3,
        disablesEnhancedUserInterface: Bool = true,
        isTimingEnabled: Bool = false,
        repeatDelay: TimeInterval = 0.25,
        repeatInterval: TimeInterval = 0.03
    ) {
        self.axTimeout = axTimeout
        self.applyInterval = applyInterval
        self.maxCorrections = maxCorrections
        self.disablesEnhancedUserInterface = disablesEnhancedUserInterface
        self.isTimingEnabled = isTimingEnabled
        self.repeatDelay = repeatDelay
        self.repeatInterval = repeatInterval
    }
}
