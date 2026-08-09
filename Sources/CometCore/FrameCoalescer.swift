import CoreGraphics

/// ウィンドウの目標矩形。
public struct TargetFrame: Equatable, Sendable {
    public var rect: CGRect

    /// `false` のとき位置だけを設定する。
    ///
    /// AX には位置とサイズを一括設定する API が無く、矩形を変えるには最低2回の IPC が要る。
    /// サイズが既に正しいと分かっている場合（ワークスペース切替からの復帰など）は
    /// 位置だけを設定して IPC を半減できる。
    public var setSize: Bool

    public init(rect: CGRect, setSize: Bool = true) {
        self.rect = rect
        self.setSize = setSize
    }
}

/// 発行すべき適用要求。
public struct FrameRequest: Equatable, Sendable {
    public let windowID: CGWindowID
    public let target: TargetFrame

    public init(windowID: CGWindowID, target: TargetFrame) {
        self.windowID = windowID
        self.target = target
    }
}

/// 目標矩形を合成し、無駄な AX 呼び出しを削る。
///
/// **症状B（リサイズ連打で追従しない・飛ぶ・戻る）への対策そのもの。**
///
/// キーリピートは 25〜30 回/秒あり、BSP では隣接ウィンドウも同時に変わるため
/// 1打鍵で最低4回の AX 呼び出しが発生する。打鍵ごとに発行するとキューが詰まり、
/// キーを離した後も溜まった分が処理され続ける。
///
/// 合成器は次の3つで発行量を抑える。
///
/// 1. **上書き** — 適用前に届いた新しい目標は古い目標を置き換える。中間状態は捨てる。
/// 2. **適用中の抑制** — 適用が完了していないウィンドウには次を投げない。
/// 3. **無変化の除去** — 適用済みと同じ目標は発行しない。
///
/// 副作用を持たない値型なので、時間もスレッドも使わずにテストできる。
/// 実際のタイマー駆動と PID ごとのキューへの振り分けは ``FrameScheduler`` が担う。
public struct FrameCoalescer {

    private var pending: [CGWindowID: TargetFrame] = [:]
    /// `pending` の順序。レイアウト適用の順序は見た目に影響するので保つ。
    private var pendingOrder: [CGWindowID] = []
    /// 最後に「発行した」目標。実際に反映されたかは問わない。
    private var applied: [CGWindowID: TargetFrame] = [:]
    private var inFlight: Set<CGWindowID> = []

    private let tolerance: CGFloat

    /// - Parameter tolerance: これ以下のずれは同一とみなす。
    ///   AX でサイズを設定してもアプリ側の制約で 1pt 未満ずれることがあり、
    ///   厳密比較だと無意味な再適用を繰り返す。
    public init(tolerance: CGFloat = 0.5) {
        self.tolerance = tolerance
    }

    // MARK: - 投入

    public mutating func submit(_ windowID: CGWindowID, _ target: TargetFrame) {
        // 既に待機中なら順序上の位置は動かさない。
        // 属性更新のたびにウィンドウが列を飛び移って見えるのを防ぐ。
        if pending[windowID] == nil {
            pendingOrder.append(windowID)
        }
        pending[windowID] = target
    }

    /// 一括投入。
    ///
    /// - Parameter order: 適用順。省略時はウィンドウ ID 昇順（辞書の反復順は不定のため、
    ///   順序を決定的にする必要がある）。
    public mutating func submit(
        _ targets: [CGWindowID: TargetFrame], order: [CGWindowID]? = nil
    ) {
        for windowID in order ?? targets.keys.sorted() {
            guard let target = targets[windowID] else { continue }
            submit(windowID, target)
        }
    }

    // MARK: - 取り出し

    /// 発行すべき要求を取り出す。取り出したものは適用中として記録される。
    public mutating func drain() -> [FrameRequest] {
        var requests: [FrameRequest] = []
        var stillPending: [CGWindowID] = []

        for windowID in pendingOrder {
            guard let target = pending[windowID] else { continue }

            // 適用中なら完了を待つ。順序上の位置は保つ。
            if inFlight.contains(windowID) {
                stillPending.append(windowID)
                continue
            }

            // 既に同じ矩形を発行済みなら AX 呼び出しは不要。
            if let previous = applied[windowID], isUnchanged(from: previous, to: target) {
                pending.removeValue(forKey: windowID)
                continue
            }

            inFlight.insert(windowID)
            applied[windowID] = target
            pending.removeValue(forKey: windowID)
            requests.append(FrameRequest(windowID: windowID, target: target))
        }

        pendingOrder = stillPending
        return requests
    }

    /// 適用が完了したことを通知する。知らないウィンドウでも無害。
    public mutating func complete(_ windowID: CGWindowID) {
        inFlight.remove(windowID)
    }

    /// 適用履歴を破棄する。
    ///
    /// アプリが目標どおりに動かなかった場合、同じ矩形を再投入しても
    /// 「適用済みと同じ」と判定されて発行されない。補正を投げ直すには
    /// 先に履歴を捨てる必要がある。
    public mutating func invalidate(_ windowID: CGWindowID) {
        applied.removeValue(forKey: windowID)
    }

    /// ウィンドウが消えたときに全ての状態を捨てる。
    ///
    /// 適用履歴も消すので、同じ ID が再利用されても前回の矩形と誤って
    /// 「無変化」と判定されない。
    public mutating func forget(_ windowID: CGWindowID) {
        pending.removeValue(forKey: windowID)
        pendingOrder.removeAll { $0 == windowID }
        applied.removeValue(forKey: windowID)
        inFlight.remove(windowID)
    }

    // MARK: - 状態

    /// 待機中も適用中も無い状態。タイマーを止めてよい合図になる。
    public var isIdle: Bool {
        pending.isEmpty && inFlight.isEmpty
    }

    public var pendingCount: Int { pending.count }
    public var inFlightCount: Int { inFlight.count }

    /// 待機中または適用中か。外部からの変更と自分の適用を区別するのに使う。
    public func isActive(_ windowID: CGWindowID) -> Bool {
        pending[windowID] != nil || inFlight.contains(windowID)
    }

    /// 最後に発行した矩形。AX 通知で観測した実結果との突き合わせに使う。
    public func appliedFrame(_ windowID: CGWindowID) -> CGRect? {
        applied[windowID]?.rect
    }

    private func isUnchanged(from previous: TargetFrame, to target: TargetFrame) -> Bool {
        previous.setSize == target.setSize
            && Geometry.isApproximatelyEqual(previous.rect, target.rect, tolerance: tolerance)
    }
}
