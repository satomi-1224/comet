import CoreGraphics
import Testing

@testable import CometCore

/// ウィンドウの台帳。
///
/// 主キーは `AXUIElement` ではなく `CGWindowID`。AX 要素は同一ウィンドウに対して
/// 複数のインスタンスが生成されうるため辞書キーに向かない。
///
/// **並び順の安定性は必須**。レイアウトは登録順に列を割り当てるので、
/// 順序が揺れるとウィンドウが理由もなく入れ替わって見える。
@MainActor
@Suite("WindowRegistry")
struct WindowRegistryTests {

    private func record(
        _ id: CGWindowID,
        pid: pid_t = 100,
        disposition: WindowDisposition = .tiled
    ) -> WindowRecord {
        WindowRecord(id: id, pid: pid, disposition: disposition)
    }

    @Test("生成直後は空")
    func startsEmpty() {
        let registry = WindowRegistry()
        #expect(registry.count == 0)
        #expect(registry.allIDs.isEmpty)
        #expect(registry[1] == nil)
    }

    @Test("登録したものを引ける")
    func insertAndLookup() {
        let registry = WindowRegistry()
        registry.insert(record(1, pid: 42))
        #expect(registry.count == 1)
        #expect(registry[1]?.pid == 42)
    }

    @Test("登録順が保たれる")
    func preservesInsertionOrder() {
        let registry = WindowRegistry()
        for id in [30, 10, 20, 5] as [CGWindowID] {
            registry.insert(record(id))
        }
        #expect(registry.allIDs == [30, 10, 20, 5])
    }

    // 属性の更新でウィンドウが列を飛び移ってはいけない。
    @Test("同じ ID の再登録は位置を変えない")
    func reinsertKeepsPosition() {
        let registry = WindowRegistry()
        registry.insert(record(1))
        registry.insert(record(2))
        registry.insert(record(3))

        registry.insert(record(2, pid: 999))

        #expect(registry.allIDs == [1, 2, 3])
        #expect(registry[2]?.pid == 999)
    }

    @Test("削除すると引けなくなり順序から外れる")
    func remove() {
        let registry = WindowRegistry()
        registry.insert(record(1))
        registry.insert(record(2))
        registry.insert(record(3))

        let removed = registry.remove(2)
        #expect(removed?.id == 2)
        #expect(registry.allIDs == [1, 3])
        #expect(registry[2] == nil)
    }

    @Test("存在しない ID の削除は nil を返し無害")
    func removeMissing() {
        let registry = WindowRegistry()
        #expect(registry.remove(99) == nil)
        #expect(registry.count == 0)
    }

    // アプリが終了したら、そのアプリのウィンドウを一括で片付ける必要がある。
    @Test("PID 単位で一括削除できる")
    func removeAllForPID() {
        let registry = WindowRegistry()
        registry.insert(record(1, pid: 100))
        registry.insert(record(2, pid: 200))
        registry.insert(record(3, pid: 100))
        registry.insert(record(4, pid: 200))

        let removed = registry.removeAll(pid: 100)
        #expect(removed == [1, 3], "削除順も登録順を保つ")
        #expect(registry.allIDs == [2, 4])
    }

    @Test("該当のない PID の一括削除は空を返す")
    func removeAllForUnknownPID() {
        let registry = WindowRegistry()
        registry.insert(record(1, pid: 100))
        #expect(registry.removeAll(pid: 999).isEmpty)
        #expect(registry.count == 1)
    }

    @Test("PID で絞り込める")
    func filterByPID() {
        let registry = WindowRegistry()
        registry.insert(record(1, pid: 100))
        registry.insert(record(2, pid: 200))
        registry.insert(record(3, pid: 100))
        #expect(registry.ids(pid: 100) == [1, 3])
        #expect(registry.ids(pid: 200) == [2])
    }

    @Test("タイル対象だけを登録順で取り出せる")
    func tiledIDsPreserveOrder() {
        let registry = WindowRegistry()
        registry.insert(record(1, disposition: .tiled))
        registry.insert(record(2, disposition: .unmanaged(.nonStandardSubrole)))
        registry.insert(record(3, disposition: .tiled))
        registry.insert(record(4, disposition: .unmanaged(.minimized)))
        registry.insert(record(5, disposition: .tiled))

        #expect(registry.tiledIDs == [1, 3, 5])
    }

    @Test("disposition を更新できる")
    func updateDisposition() {
        let registry = WindowRegistry()
        registry.insert(record(1, disposition: .unmanaged(.minimized)))
        #expect(registry.tiledIDs.isEmpty)

        registry.update(1) { $0.disposition = .tiled }
        #expect(registry.tiledIDs == [1])
    }

    @Test("存在しない ID の更新は無害")
    func updateMissingIsHarmless() {
        let registry = WindowRegistry()
        registry.update(99) { $0.disposition = .tiled }
        #expect(registry.count == 0)
    }

    @Test("観測した矩形を記録できる")
    func recordObservedFrame() {
        let registry = WindowRegistry()
        registry.insert(record(1))
        let frame = CGRect(x: 10, y: 20, width: 300, height: 400)
        registry.update(1) { $0.observedFrame = frame }
        #expect(registry[1]?.observedFrame == frame)
    }

    // 起動時は各アプリの走査が非同期に完了するため登録順が実行ごとに変わる。
    // レイアウトは登録順に領域を割り当てるので、整列できないと
    // 同じ環境で起動しても並びが入れ替わって見える。
    @Test("並び順を整列できる")
    func sortReordersDeterministically() {
        let registry = WindowRegistry()
        for id in [30, 10, 20] as [CGWindowID] {
            registry.insert(record(id))
        }
        registry.sort { $0.id < $1.id }
        #expect(registry.allIDs == [10, 20, 30])
    }

    @Test("整列は tiledIDs にも反映される")
    func sortAffectsTiledIDs() {
        let registry = WindowRegistry()
        registry.insert(record(30, disposition: .tiled))
        registry.insert(record(10, disposition: .unmanaged(.minimized)))
        registry.insert(record(20, disposition: .tiled))
        registry.sort { $0.id < $1.id }
        #expect(registry.tiledIDs == [20, 30])
    }

    @Test("全消去できる")
    func removeAll() {
        let registry = WindowRegistry()
        registry.insert(record(1))
        registry.insert(record(2))
        registry.removeAll()
        #expect(registry.count == 0)
        #expect(registry.allIDs.isEmpty)
    }

    @Test("登録済みの PID 一覧を取得できる")
    func knownPIDs() {
        let registry = WindowRegistry()
        registry.insert(record(1, pid: 100))
        registry.insert(record(2, pid: 200))
        registry.insert(record(3, pid: 100))
        #expect(Set(registry.knownPIDs) == [100, 200])
    }
}
