import CoreGraphics
import Darwin

/// ウィンドウ1枚分の台帳エントリ。
///
/// `AXUIElement` はここには持たない。AX 要素は同一ウィンドウに対して複数の
/// インスタンスが生成されうるうえ Sendable でもないため、
/// AX 層（`AXWindowStore`）が別に保持する。こうすることで台帳は
/// AX 抜きでテストできる純粋なデータになる。
public struct WindowRecord: Equatable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public var disposition: WindowDisposition
    public var title: String?
    public var bundleID: String?
    /// AX 通知で観測した実際の矩形。目標との突き合わせに使う。
    public var observedFrame: CGRect?

    public init(
        id: CGWindowID,
        pid: pid_t,
        disposition: WindowDisposition,
        title: String? = nil,
        bundleID: String? = nil,
        observedFrame: CGRect? = nil
    ) {
        self.id = id
        self.pid = pid
        self.disposition = disposition
        self.title = title
        self.bundleID = bundleID
        self.observedFrame = observedFrame
    }
}

/// ウィンドウの台帳。主キーは `CGWindowID`。
///
/// **並び順の安定性は必須。** レイアウトは登録順に列を割り当てるため、
/// 順序が揺れるとウィンドウが理由もなく入れ替わって見える。
/// 属性の更新では位置を動かさない。
@MainActor
public final class WindowRegistry {

    private var records: [CGWindowID: WindowRecord] = [:]
    private var order: [CGWindowID] = []

    public init() {}

    // MARK: - 更新

    /// 登録する。既存の ID なら内容を置き換えるが**順序上の位置は保つ**。
    public func insert(_ record: WindowRecord) {
        if records[record.id] == nil {
            order.append(record.id)
        }
        records[record.id] = record
    }

    @discardableResult
    public func remove(_ id: CGWindowID) -> WindowRecord? {
        guard let record = records.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        return record
    }

    /// アプリ終了時に、そのアプリのウィンドウを一括で片付ける。
    ///
    /// - Returns: 削除した ID。登録順を保つ。
    @discardableResult
    public func removeAll(pid: pid_t) -> [CGWindowID] {
        let targets = order.filter { records[$0]?.pid == pid }
        guard !targets.isEmpty else { return [] }
        let targetSet = Set(targets)
        for id in targets {
            records.removeValue(forKey: id)
        }
        order.removeAll { targetSet.contains($0) }
        return targets
    }

    /// 登録順を並べ替える。
    ///
    /// 起動時は各アプリの走査が非同期に完了するため、登録順が実行ごとに変わりうる。
    /// レイアウトは登録順に領域を割り当てるので、そのままだと起動のたびに
    /// ウィンドウの並びが入れ替わって見える。走査が一巡した時点で整列させる。
    public func sort(by areInIncreasingOrder: (WindowRecord, WindowRecord) -> Bool) {
        order.sort { lhs, rhs in
            guard let left = records[lhs], let right = records[rhs] else { return false }
            return areInIncreasingOrder(left, right)
        }
    }

    public func removeAll() {
        records.removeAll()
        order.removeAll()
    }

    /// 既存エントリを書き換える。存在しない ID なら何もしない。
    public func update(_ id: CGWindowID, _ body: (inout WindowRecord) -> Void) {
        guard var record = records[id] else { return }
        body(&record)
        records[id] = record
    }

    // MARK: - 参照

    public subscript(id: CGWindowID) -> WindowRecord? {
        records[id]
    }

    public var count: Int { records.count }

    /// 登録順のウィンドウ ID。
    public var allIDs: [CGWindowID] { order }

    /// タイル対象だけを登録順で返す。レイアウト計算の入力になる。
    public var tiledIDs: [CGWindowID] {
        order.filter { records[$0]?.disposition.isTiled == true }
    }

    public func ids(pid: pid_t) -> [CGWindowID] {
        order.filter { records[$0]?.pid == pid }
    }

    public var knownPIDs: [pid_t] {
        var seen = Set<pid_t>()
        var result: [pid_t] = []
        for id in order {
            guard let pid = records[id]?.pid, seen.insert(pid).inserted else { continue }
            result.append(pid)
        }
        return result
    }
}
