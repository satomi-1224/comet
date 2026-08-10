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

    public init(
        axTimeout: TimeInterval = 0.1,
        applyInterval: TimeInterval = 0.008,
        maxCorrections: Int = 3,
        disablesEnhancedUserInterface: Bool = true,
        isTimingEnabled: Bool = false
    ) {
        self.axTimeout = axTimeout
        self.applyInterval = applyInterval
        self.maxCorrections = maxCorrections
        self.disablesEnhancedUserInterface = disablesEnhancedUserInterface
        self.isTimingEnabled = isTimingEnabled
    }
}
