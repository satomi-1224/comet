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

    /// 適用後に読み戻して結果を確かめるか。
    ///
    /// ドラッグ追従中は1フレームあたりの往復を削りたいので省略する。
    /// 正確さはドラッグが終わったあとの仕上げの適用で担保する。
    public var verify: Bool

    public init(rect: CGRect, setSize: Bool = true, verify: Bool = true) {
        self.rect = rect
        self.setSize = setSize
        self.verify = verify
    }
}

/// 発行すべき適用要求。
public struct FrameRequest: Equatable, Sendable {
    public let windowID: CGWindowID
    public let target: TargetFrame
    /// 発行ごとに異なる識別子。
    ///
    /// `forget` しても、すでに AX へ渡した処理そのものは止められない。その完了が
    /// あとから返ったとき、同じウィンドウ ID の新しい要求と取り違えないために使う。
    public let requestID: UInt64

    public init(windowID: CGWindowID, target: TargetFrame, requestID: UInt64 = 0) {
        self.windowID = windowID
        self.target = target
        self.requestID = requestID
    }
}

/// 発行済み要求の完了を、現在の目標との関係で分類したもの。
public enum FrameCompletion: Equatable, Sendable {
    /// 今も最新の要求（同じ目標の再投入を含む）。結果の反映と補正を続けてよい。
    case current
    /// 適用中に別の目標が届いた。古い結果で状態や新しい目標を上書きしてはいけない。
    case superseded
    /// `forget` 済み、または同じウィンドウ ID に対する過去の要求。
    case discarded
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
    /// 適用中の要求。値は発行ごとに異なる ID。
    ///
    /// ウィンドウ ID だけでは、`forget` 前の古い完了と、その後に発行した新しい要求を
    /// 区別できない。古い完了で新しい適用中フラグを消すと、同じ窓へ複数の AX 書き込みが
    /// 並行してしまう。
    private var inFlight: [CGWindowID: UInt64] = [:]
    private var nextRequestID: UInt64 = 0

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
            if inFlight[windowID] != nil {
                stillPending.append(windowID)
                continue
            }

            // 既に同じ矩形を発行済みなら AX 呼び出しは不要。
            if let previous = applied[windowID], isUnchanged(from: previous, to: target) {
                pending.removeValue(forKey: windowID)
                continue
            }

            // 0 は外から組み立てた `FrameRequest` の既定値として予約する。
            repeat { nextRequestID &+= 1 } while nextRequestID == 0
            let requestID = nextRequestID
            inFlight[windowID] = requestID
            applied[windowID] = target
            pending.removeValue(forKey: windowID)
            requests.append(
                FrameRequest(windowID: windowID, target: target, requestID: requestID))
        }

        pendingOrder = stillPending
        return requests
    }

    /// 適用が完了したことを通知する。
    ///
    /// - Returns: 今の目標との関係。適用中に新しい目標が届いていれば
    ///   ``FrameCompletion/superseded`` として返し、古い補正による巻き戻しを防ぐ。
    @discardableResult
    public mutating func complete(_ request: FrameRequest) -> FrameCompletion {
        guard inFlight[request.windowID] == request.requestID else { return .discarded }
        inFlight.removeValue(forKey: request.windowID)
        guard let newer = pending[request.windowID] else { return .current }
        return isUnchanged(from: request.target, to: newer) ? .current : .superseded
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
        inFlight.removeValue(forKey: windowID)
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
        pending[windowID] != nil || inFlight[windowID] != nil
    }

    /// 最後に発行した矩形。AX 通知で観測した実結果との突き合わせに使う。
    public func appliedFrame(_ windowID: CGWindowID) -> CGRect? {
        applied[windowID]?.rect
    }

    private func isUnchanged(from previous: TargetFrame, to target: TargetFrame) -> Bool {
        previous.setSize == target.setSize
            && previous.verify == target.verify
            && Geometry.isApproximatelyEqual(previous.rect, target.rect, tolerance: tolerance)
    }
}
