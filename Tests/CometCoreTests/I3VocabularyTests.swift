import CoreGraphics
import Testing

@testable import CometCore

/// i3 の語彙。
///
/// **目標は「i3 と同じ操作感」。** 指が覚えている綴りで通らないと、
/// 設定を書き写した時点で無反応になり、原因が設定なのか実装なのか分からない。
/// i3 の綴りと comet（AeroSpace 互換）の綴りの両方を受ける。
@Suite("i3 の語彙")
struct I3VocabularyTests {

    // MARK: - exec

    /// i3 の `$mod+Return exec <terminal>` は最も使う操作。**これが無いと起点が作れない。**
    @Test("exec は引数を分解せずシェルへ渡す1行として受ける")
    func execKeepsTheWholeLine() throws {
        #expect(try Command.parse("exec open -a Terminal") == .exec("open -a Terminal"))
        // 空白も引用符もそのまま。分解して繋ぎ直すと意味が変わる。
        #expect(
            try Command.parse("exec /bin/sh -c 'echo  a   b'")
                == .exec("/bin/sh -c 'echo  a   b'"))
        // AeroSpace の綴りでも同じ結果になる。
        #expect(try Command.parse("exec-and-forget open -a Safari") == .exec("open -a Safari"))
    }

    @Test("exec に引数が無ければ誤りとして扱う")
    func execNeedsACommand() {
        #expect(throws: Command.ParseError.self) { try Command.parse("exec") }
        #expect(throws: Command.ParseError.self) { try Command.parse("exec   ") }
    }

    // MARK: - i3 の別名

    @Test("i3 の綴りでも通る")
    func i3SpellingsAreAccepted() throws {
        #expect(try Command.parse("kill") == .closeWindow)
        #expect(try Command.parse("reload") == .reloadConfig)
        #expect(try Command.parse("focus mode_toggle") == .focusLayer(.toggle))
        #expect(try Command.parse("focus mode-toggle") == .focusLayer(.toggle))
        #expect(try Command.parse("split h") == .split(.horizontal))
        #expect(try Command.parse("split v") == .split(.vertical))
        #expect(try Command.parse("split toggle") == .split(.opposite))
        #expect(try Command.parse("layout toggle split") == .layout([.horizontal, .vertical]))
        #expect(try Command.parse("workspace back_and_forth") == .workspace(.backAndForth))
    }

    @Test("階層の上下移動を解釈する")
    func containerFocusIsParsed() throws {
        #expect(try Command.parse("focus parent") == .focusContainer(.parent))
        #expect(try Command.parse("focus child") == .focusContainer(.child))
    }

    @Test("番号順の移動を解釈する")
    func workspaceStepsAreParsed() throws {
        #expect(try Command.parse("workspace next") == .workspace(.next))
        #expect(try Command.parse("workspace prev") == .workspace(.previous))
        #expect(try Command.parse("workspace previous") == .workspace(.previous))
        #expect(try Command.parse("move-node-to-workspace next") == .moveNodeToWorkspace(.next))
        #expect(
            try Command.parse("move-node-to-workspace back-and-forth")
                == .moveNodeToWorkspace(.backAndForth))
    }

    @Test("split の引数が読めなければ誤りとして扱う")
    func splitRejectsUnknownArguments() {
        #expect(throws: Command.ParseError.self) { try Command.parse("split diagonal") }
        #expect(throws: Command.ParseError.self) { try Command.parse("split") }
        #expect(throws: Command.ParseError.self) { try Command.parse("split h v") }
    }
}

/// 番号順のワークスペース移動。**端では巻き戻る**（i3 と同じ）。
@Suite("ワークスペースの番号送り")
struct WorkspaceStepTests {

    @Test("次と前へ進む")
    func stepsForwardAndBackward() {
        let manager = WorkspaceManager(count: 10)
        #expect(manager.id(offsetFrom: 1, by: 1) == 2)
        #expect(manager.id(offsetFrom: 5, by: -1) == 4)
    }

    /// 巻き戻さないと、端でキーが無反応になって「効いていない」と見える。
    @Test("端では巻き戻る")
    func wrapsAtTheEnds() {
        let manager = WorkspaceManager(count: 10)
        #expect(manager.id(offsetFrom: 10, by: 1) == 1)
        #expect(manager.id(offsetFrom: 1, by: -1) == 10)
    }

    @Test("1個しか無ければ動かない")
    func aSingleWorkspaceStaysPut() {
        let manager = WorkspaceManager(count: 1)
        #expect(manager.id(offsetFrom: 1, by: 1) == 1)
        #expect(manager.id(offsetFrom: 1, by: -1) == 1)
    }
}

/// `focus parent` で選んだコンテナに対する操作。
///
/// i3 では、入れ子をまとめて動かす・向きを変えるのにこれを使う。
@Suite("コンテナを対象にした操作")
struct ContainerOperationTests {

    private func h(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .horizontal, children: children)
    }
    private func v(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .vertical, children: children)
    }
    private func w(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    /// `H[1, V[2, 3]]` で V を選んで `move left` すると、2と3がまとまって左へ動く。
    @Test("コンテナごと動かせる")
    func aContainerMovesAsAWhole() throws {
        let root = h(w(1), v(w(2), w(3)))
        let container = try #require(root.children[1] as? ContainerNode)
        #expect(TreeOperations.move(container, direction: .left))
        #expect(root.description == "H[V[2, 3], 1]")
    }

    /// 葉を選んでいるときは親の向きが変わる。コンテナを選んでいるときは自分の向き。
    @Test("向きの変更はコンテナ自身に効く")
    func orientationAppliesToTheSelectedContainer() throws {
        let root = h(w(1), v(w(2), w(3)))
        let container = try #require(root.children[1] as? ContainerNode)

        #expect(TreeOperations.cycleOrientation(of: container, among: [.horizontal, .vertical]))
        #expect(container.orientation == .horizontal)

        // 葉を選んだ場合は親（= container）が対象。
        let leaf = try #require(root.findWindow(2))
        #expect(TreeOperations.cycleOrientation(of: leaf, among: [.horizontal, .vertical]))
        #expect(container.orientation == .vertical)
    }

    /// ルートを選べばワークスペース全体の向きを変えられる。
    @Test("ルートの向きも変えられる")
    func theRootOrientationCanChange() {
        let root = h(w(1), w(2))
        #expect(TreeOperations.cycleOrientation(of: root, among: [.horizontal, .vertical]))
        #expect(root.orientation == .vertical)
    }

    /// **コンテナからの方向フォーカスは外へ出る。** 中の葉ではなく隣を見る。
    @Test("コンテナからの方向フォーカスは隣へ出る")
    func focusFromAContainerLeavesIt() throws {
        let root = h(w(1), v(w(2), w(3)))
        let container = try #require(root.children[1] as? ContainerNode)
        #expect(TreeOperations.focusTarget(from: container, direction: .left)?.windowID == 1)
    }
}

/// 入れ子をほどく（`flatten-workspace-tree`）。
@Suite("ツリーを平らにする")
struct FlattenTests {

    private func h(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .horizontal, children: children)
    }
    private func v(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .vertical, children: children)
    }
    private func w(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    /// **並び順は葉の深さ優先順を保つ。** 画面上の見た目の順番がそのまま列になる。
    @Test("入れ子をほどいてルート直下に並べる")
    func nestedContainersAreFlattened() {
        let root = h(w(1), v(w(2), h(w(3), w(4))))
        #expect(TreeOperations.flatten(root))
        #expect(root.description == "H[1, 2, 3, 4]")
        #expect(root.invariantViolations().isEmpty)
    }

    @Test("既に平らなら何もしない")
    func anAlreadyFlatTreeIsUntouched() {
        let root = h(w(1), w(2), w(3))
        #expect(!TreeOperations.flatten(root))
        #expect(root.description == "H[1, 2, 3]")
    }

    @Test("空のツリーでも落ちない")
    func anEmptyTreeIsSafe() {
        let root = ContainerNode(orientation: .horizontal)
        #expect(!TreeOperations.flatten(root))
        #expect(root.isEmpty)
    }

    /// ほどいたあとは比率が均等に配り直される（元の比を保つ根拠が無い）。
    @Test("ほどいたあとの比率は均等")
    func weightsAreEvenAfterFlattening() {
        let root = h(w(1), v(w(2), w(3)))
        root.setWeights([0.8, 0.2])
        #expect(TreeOperations.flatten(root))
        #expect(root.weights.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 })
    }
}

/// `split h` / `split v` の予約。
///
/// **その場では木を変えない。** 子が1つのコンテナは正規化で潰されるので作っても残らない。
/// 次の1枚が来たときに使う。
@Suite("次のウィンドウの分割方向")
struct PendingSplitTests {

    private func reconcile(
        _ root: ContainerNode, _ tiled: [CGWindowID], focused: CGWindowID?,
        split: (windowID: CGWindowID, orientation: Orientation)? = nil
    ) {
        TreeSync.reconcile(
            root: root, tiled: tiled, focused: focused, strategy: .split, split: split)
    }

    /// 既定（dwindle）では親と逆向きに割れる。指定すればその向きになる。
    @Test("指定した向きで分割して入る")
    func theRequestedOrientationIsUsed() {
        let root = ContainerNode(orientation: .horizontal)
        reconcile(root, [1, 2], focused: nil)
        #expect(root.description == "H[1, 2]")

        // 既定なら 2 の領域が縦に割れる（H の逆）。
        let dwindle = ContainerNode(orientation: .horizontal)
        reconcile(dwindle, [1, 2], focused: nil)
        reconcile(dwindle, [1, 2, 3], focused: 2)
        #expect(dwindle.description == "H[1, V[2, 3]]")

        // 横を指定すれば 2 の隣に並ぶ（親が既に横なので入れ子を作らない）。
        reconcile(root, [1, 2, 3], focused: 2, split: (windowID: 2, orientation: .horizontal))
        #expect(root.description == "H[1, 2, 3]")
    }

    @Test("親と違う向きを指定したらコンテナを作る")
    func aDifferentOrientationWrapsTheAnchor() {
        let root = ContainerNode(orientation: .horizontal)
        reconcile(root, [1, 2], focused: nil)
        reconcile(root, [1, 2, 3], focused: 2, split: (windowID: 2, orientation: .vertical))
        #expect(root.description == "H[1, V[2, 3]]")
    }

    /// **選んだ向きは正規化で反転させない。** 反転させると、指定したそばから戻る。
    @Test("指定した向きは正規化で反転されない")
    func theChosenOrientationSurvivesNormalization() throws {
        let root = ContainerNode(orientation: .horizontal)
        reconcile(root, [1, 2], focused: nil)
        // 親が H のときに H を指定 → 兄弟として並ぶ（入れ子にしない）。
        reconcile(root, [1, 2, 3], focused: 2, split: (windowID: 2, orientation: .horizontal))
        #expect(root.description == "H[1, 2, 3]")

        // V を指定して作ったコンテナは明示扱い。
        let nested = ContainerNode(orientation: .vertical)
        reconcile(nested, [1, 2], focused: nil)
        reconcile(nested, [1, 2, 3], focused: 2, split: (windowID: 2, orientation: .vertical))
        #expect(nested.description == "V[1, 2, 3]")
    }

    /// 基準が違えば効かない。**別のウィンドウを選んでから開いても予約が残らない。**
    @Test("基準のウィンドウが違えば効かない")
    func theReservationIsTiedToItsAnchor() {
        let root = ContainerNode(orientation: .horizontal)
        reconcile(root, [1, 2], focused: nil)
        reconcile(root, [1, 2, 3], focused: 1, split: (windowID: 2, orientation: .vertical))
        // 1 を基準にした既定の入り方（H の逆＝縦）になる。
        #expect(root.description == "H[V[1, 3], 2]")
    }
}

/// モニタ間の移動（i3 の output）。
///
/// **2画面で使う人にとってこれが無いと i3 の代わりにならない。**
/// AeroSpace の綴り（`focus-monitor next`）と i3 の綴り（`focus output right`）の
/// 両方を受ける。
@Suite("モニタ間の移動")
struct MonitorCommandTests {

    @Test("comet / AeroSpace の綴り")
    func aerospaceSpellings() throws {
        #expect(try Command.parse("focus-monitor next") == .focusMonitor(.next))
        #expect(try Command.parse("focus-monitor prev") == .focusMonitor(.previous))
        #expect(try Command.parse("focus-monitor main") == .focusMonitor(.main))
        #expect(try Command.parse("focus-monitor left") == .focusMonitor(.left))
        #expect(try Command.parse("focus-monitor right") == .focusMonitor(.right))
        #expect(try Command.parse("move-node-to-monitor next") == .moveNodeToMonitor(.next))
        #expect(
            try Command.parse("move-workspace-to-monitor right")
                == .moveWorkspaceToMonitor(.right))
    }

    @Test("i3 の綴り")
    func i3Spellings() throws {
        #expect(try Command.parse("focus output right") == .focusMonitor(.right))
        #expect(try Command.parse("focus output primary") == .focusMonitor(.main))
        #expect(
            try Command.parse("move container to output right") == .moveNodeToMonitor(.right))
        #expect(
            try Command.parse("move workspace to output next")
                == .moveWorkspaceToMonitor(.next))
        #expect(
            try Command.parse("move container to workspace 4")
                == .moveNodeToWorkspace(.index(4)))
    }

    @Test("読めない指定は誤りとして扱う")
    func unknownTargetsAreRejected() {
        #expect(throws: Command.ParseError.self) { try Command.parse("focus-monitor up") }
        #expect(throws: Command.ParseError.self) { try Command.parse("focus-monitor") }
        #expect(throws: Command.ParseError.self) { try Command.parse("focus output sideways") }
        #expect(throws: Command.ParseError.self) {
            try Command.parse("move nothing to output right")
        }
    }

    @Test("綴りへ戻せる")
    func roundTrips() throws {
        for spec in [
            "focus-monitor next", "focus-monitor prev", "focus-monitor main",
            "focus-monitor left", "focus-monitor right",
            "move-node-to-monitor next", "move-workspace-to-monitor prev",
        ] {
            let command = try Command.parse(spec)
            #expect(command.description == spec, "\(command)")
        }
    }
}
