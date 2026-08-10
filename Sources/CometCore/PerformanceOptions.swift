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

    public init(
        axTimeout: TimeInterval = 0.1,
        applyInterval: TimeInterval = 0.008,
        maxCorrections: Int = 3
    ) {
        self.axTimeout = axTimeout
        self.applyInterval = applyInterval
        self.maxCorrections = maxCorrections
    }
}
