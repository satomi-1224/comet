import CoreGraphics
import Testing

@testable import CometCore

/// ツリーを操作するコマンド。**メモリ操作だけで完結する**のが要点。
///
/// AX 適用は後段の `FrameScheduler` でコアレスされるので、連打しても往復は増えない。
/// これが症状B（リサイズ連打で追従しない）の対策の本体。
@Suite("TreeCommands")
struct TreeCommandTests {

    private func h(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .horizontal, children: children)
    }

    private func v(_ children: Node...) -> ContainerNode {
        ContainerNode(orientation: .vertical, children: children)
    }

    private func w(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    private func node(_ root: ContainerNode, _ id: CGWindowID) throws -> WindowNode {
        try #require(root.findWindow(id))
    }

    private func layout(_ root: ContainerNode) -> LayoutEngine.Result {
        LayoutEngine.compute(
            root: root, area: CGRect(x: 0, y: 0, width: 1000, height: 600), gaps: .zero, scale: 2)
    }

    // MARK: - focus

    @Test("右隣の兄弟へ移る")
    func focusRightMovesToSibling() throws {
        let root = h(w(1), w(2), w(3))
        let first = try node(root, 1)
        let second = try node(root, 2)

        #expect(TreeOperations.focusTarget(from: first, direction: .right)?.windowID == 2)
        #expect(TreeOperations.focusTarget(from: second, direction: .left)?.windowID == 1)
    }

    @Test("軸が合わない親は飛ばして祖先を遡る")
    func focusAscendsWhenNoSibling() throws {
        // H[1, V[2, 3]] の 2 から左へ。V は縦なので飛ばし、ルートで 1 を見つける。
        let root = h(w(1), v(w(2), w(3)))
        let second = try node(root, 2)
        #expect(TreeOperations.focusTarget(from: second, direction: .left)?.windowID == 1)
    }

    @Test("端では行き先が無い")
    func focusAtEdgeHasNoTarget() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)
        let second = try node(root, 2)

        #expect(TreeOperations.focusTarget(from: first, direction: .left) == nil)
        #expect(TreeOperations.focusTarget(from: second, direction: .right) == nil)
        #expect(TreeOperations.focusTarget(from: first, direction: .up) == nil, "縦の分割が無い")
    }

    @Test("コンテナへ降りるときは最後にフォーカスした葉を選ぶ")
    func focusDescendsToMostRecentlyFocusedLeaf() throws {
        let root = h(w(1), v(w(2), w(3)))
        let first = try node(root, 1)
        let second = try node(root, 2)
        let third = try node(root, 3)

        third.lastFocusedAt = 100
        #expect(TreeOperations.focusTarget(from: first, direction: .right)?.windowID == 3)

        second.lastFocusedAt = 200
        #expect(TreeOperations.focusTarget(from: first, direction: .right)?.windowID == 2)
    }

    @Test("同点なら深さ優先で最初の葉を選ぶ")
    func focusDescendsDeterministicallyOnTies() throws {
        let root = h(w(1), v(w(2), w(3)))
        let first = try node(root, 1)
        #expect(TreeOperations.focusTarget(from: first, direction: .right)?.windowID == 2)
    }

    @Test("下方向は AX 座標系で添字が増える向き")
    func focusDownGoesTowardIncreasingIndex() throws {
        let root = v(w(1), w(2))
        let first = try node(root, 1)
        let second = try node(root, 2)

        #expect(TreeOperations.focusTarget(from: first, direction: .down)?.windowID == 2)
        #expect(TreeOperations.focusTarget(from: second, direction: .up)?.windowID == 1)
    }

    // MARK: - move

    @Test("兄弟のウィンドウとは位置を入れ替える")
    func moveSwapsSiblings() throws {
        let root = h(w(1), w(2), w(3))
        #expect(TreeOperations.move(try node(root, 1), direction: .right))
        #expect(root.description == "H[2, 1, 3]")
    }

    @Test("入れ替えでは比率も一緒に動く")
    func moveCarriesWeight() throws {
        let root = h(w(1), w(2))
        root.setWeights([0.7, 0.3])
        #expect(TreeOperations.move(try node(root, 1), direction: .right))
        #expect(abs(root.weights[1] - 0.7) < 1e-9, "\(root.weights)")
    }

    @Test("隣がコンテナならその中の近い端へ入る")
    func moveEntersAdjacentContainer() throws {
        let root = h(w(1), v(w(2), w(3)))
        #expect(TreeOperations.move(try node(root, 1), direction: .right))
        #expect(root.description == "H[V[1, 2, 3]]", "右へ動いたので V の先頭に入る")
    }

    @Test("逆向きならコンテナの末尾へ入る")
    func moveEntersAdjacentContainerFromTheOtherSide() throws {
        let root = h(v(w(1), w(2)), w(3))
        #expect(TreeOperations.move(try node(root, 3), direction: .left))
        #expect(root.description == "H[V[1, 2, 3]]")
    }

    @Test("入れ子から抜けて祖先の隣へ出る")
    func moveEscapesNestedContainer() throws {
        let root = h(v(w(1), w(2)), w(3))
        #expect(TreeOperations.move(try node(root, 1), direction: .right))
        #expect(root.description == "H[V[2], 1, 3]", "抜けた先は元のコンテナの直後")
    }

    // 端でも「外へ出る」ことはできる。出口が無いのは軸の祖先そのものが無いときだけ。
    @Test("祖先の端では端の外へ出る")
    func moveEscapesAtTheEdge() throws {
        let root = h(v(w(1), w(2)), w(3))
        #expect(TreeOperations.move(try node(root, 1), direction: .left))
        #expect(root.description == "H[1, V[2], 3]")
    }

    // 抜けた先にコンテナがあるなら中へ入る。ここで「隣に新しい列を作る」と、
    // 同じ操作が浅いところでは中へ入り、深いところでは列を作る、と不揃いになる。
    @Test("入れ子から抜けるとき隣がコンテナならその中へ入る")
    func moveEscapesIntoAdjacentContainer() throws {
        let root = ContainerNode(
            orientation: .horizontal, children: [v(w(1), w(2)), v(w(3), w(4))])
        #expect(TreeOperations.move(try node(root, 1), direction: .right))
        #expect(root.description == "H[V[2], V[1, 3, 4]]")
    }

    @Test("自分の親の端では動かない")
    func moveDoesNothingAtOwnEdge() throws {
        let root = h(w(1), w(2))
        #expect(!TreeOperations.move(try node(root, 1), direction: .left))
        #expect(root.description == "H[1, 2]")
    }

    @Test("軸の祖先が無ければ動かない")
    func moveDoesNothingWithoutMatchingAxis() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)

        #expect(!TreeOperations.move(first, direction: .up))
        #expect(!TreeOperations.move(first, direction: .down))
        #expect(root.description == "H[1, 2]")
    }

    @Test("どの向きへ何度動かしてもウィンドウを失わない")
    func movePreservesAllWindows() throws {
        let root = h(v(w(1), w(2)), w(3), v(w(4), w(5)))

        for direction in Direction.allCases {
            for id in CGWindowID(1)...CGWindowID(5) {
                guard let target = root.findWindow(id) else {
                    #expect(Bool(false), "[\(id)] が見つからない: \(root)")
                    continue
                }
                _ = TreeOperations.move(target, direction: direction)
                Normalization.normalize(root)
                #expect(Set(root.windowIDs).count == 5, "\(direction) \(id) の後: \(root)")
                #expect(root.invariantViolations().isEmpty, "\(root)")
            }
        }
    }

    // MARK: - resize

    @Test("幅を増やすと隣が同量減る")
    func resizeAdjustsOnlyTwoWeights() throws {
        let root = h(w(1), w(2), w(3))
        let before = root.weights
        let first = try node(root, 1)

        #expect(TreeOperations.resize(first, dimension: .width, delta: 100, layout: layout(root)))

        // 配分できる長さは 1000。100pt は 0.1 にあたる。
        #expect(abs(root.weights[0] - (before[0] + 0.1)) < 1e-9, "\(root.weights)")
        #expect(abs(root.weights[1] - (before[1] - 0.1)) < 1e-9, "\(root.weights)")
        #expect(abs(root.weights[2] - before[2]) < 1e-9, "3枚目は動かない")
    }

    @Test("最後の子なら手前の境界を動かす")
    func resizeLastChildMovesPrecedingBoundary() throws {
        let root = h(w(1), w(2))
        let second = try node(root, 2)

        #expect(TreeOperations.resize(second, dimension: .width, delta: 100, layout: layout(root)))
        #expect(abs(root.weights[1] - 0.6) < 1e-9, "\(root.weights)")
        #expect(abs(root.weights[0] - 0.4) < 1e-9, "\(root.weights)")
    }

    @Test("負の量なら縮む")
    func resizeShrinksOnNegativeDelta() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)

        #expect(TreeOperations.resize(first, dimension: .width, delta: -200, layout: layout(root)))
        #expect(abs(root.weights[0] - 0.3) < 1e-9, "\(root.weights)")
    }

    @Test("軸の祖先が無ければ何もしない")
    func resizeDoesNothingWithoutMatchingAxis() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)
        #expect(!TreeOperations.resize(first, dimension: .height, delta: 100, layout: layout(root)))
    }

    @Test("下限で止まり、潰れない")
    func resizeClampsAtMinimum() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)

        for _ in 0..<20 {
            _ = TreeOperations.resize(first, dimension: .width, delta: 200, layout: layout(root))
        }
        #expect(root.weights[1] >= 0.05 - 1e-9, "\(root.weights)")
        #expect(abs(root.weights.reduce(0, +) - 1) < 1e-9)
    }

    @Test("上限に達したら変化なしとして false を返す")
    func resizeReportsNoChangeWhenClamped() throws {
        let root = h(w(1), w(2))
        root.setWeights([0.95, 0.05])
        let first = try node(root, 1)
        #expect(!TreeOperations.resize(first, dimension: .width, delta: 100, layout: layout(root)))
    }

    @Test("入れ子では最も近い軸の祖先を動かす")
    func resizeUsesNearestAncestorOnTheAxis() throws {
        let inner = v(w(2), w(3))
        let root = ContainerNode(orientation: .horizontal, children: [w(1), inner])
        let rootWeights = root.weights
        let second = try node(root, 2)

        #expect(TreeOperations.resize(second, dimension: .height, delta: 60, layout: layout(root)))
        #expect(root.weights == rootWeights, "外側は動かない")
        // V が配分できる長さは 600。60pt は 0.1。
        #expect(abs(inner.weights[0] - 0.6) < 1e-9, "\(inner.weights)")
    }

    // MARK: - 境界の移動（手動リサイズの受け口）

    @Test("観測した辺の位置へ境界を動かせる")
    func moveBoundaryToObservedEdge() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)
        let result = layout(root)

        let match = try #require(
            result.match(edge: 500, of: first, orientation: .horizontal, tolerance: 2))
        #expect(TreeOperations.moveBoundary(match.boundary, to: 600))
        #expect(abs(root.weights[0] - 0.6) < 1e-9, "\(root.weights)")
    }

    // ドラッグ中は同じ辺について通知が何度も届く。基準が古いままだと同じ量を
    // 何度も足してしまい、追従が暴走する（実機で踏んだ失敗）。
    @Test("今の比率を基準にすれば同じ観測値を二度反映しても動かない")
    func repeatedBoundaryMoveIsIdempotent() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)

        let before = layout(root)
        let match = try #require(
            before.match(edge: 500, of: first, orientation: .horizontal, tolerance: 2))
        #expect(TreeOperations.moveBoundary(match.boundary, to: 600))
        let once = root.weights

        let after = layout(root)
        let refreshed = try #require(after.boundary(like: match.boundary))
        #expect(!TreeOperations.moveBoundary(refreshed, to: 600), "動かす余地が無い")
        #expect(root.weights == once)
    }

    // 上の対処が要る理由を残しておく。基準を作り直さないとこうなる。
    @Test("古い境界を基準にすると二重に動く")
    func staleBoundaryDoubleApplies() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)
        let stale = layout(root)
        let match = try #require(
            stale.match(edge: 500, of: first, orientation: .horizontal, tolerance: 2))

        TreeOperations.moveBoundary(match.boundary, to: 600)
        let once = root.weights[0]
        TreeOperations.moveBoundary(match.boundary, to: 600)
        #expect(root.weights[0] > once, "\(root.weights)")
    }

    @Test("境界の引き直しは同じコンテナの同じ位置を指す")
    func refreshedBoundaryIdentifiesTheSameSplit() throws {
        let inner = v(w(2), w(3))
        let root = ContainerNode(orientation: .horizontal, children: [w(1), inner])
        let result = layout(root)

        let vertical = try #require(result.boundaries.first { $0.container === inner })
        let refreshed = try #require(layout(root).boundary(like: vertical))
        #expect(refreshed.container === inner)
        #expect(refreshed.leadingIndex == vertical.leadingIndex)
    }

    // MARK: - join-with

    @Test("右隣と新しいコンテナを作る")
    func joinWithRightCreatesContainer() throws {
        let root = h(w(1), w(2), w(3))
        #expect(TreeOperations.joinWith(try node(root, 1), direction: .right))
        #expect(root.description == "H[H[1, 2], 3]")
    }

    @Test("左隣なら並び順は隣が先")
    func joinWithLeftKeepsGeometricOrder() throws {
        let root = h(w(1), w(2), w(3))
        #expect(TreeOperations.joinWith(try node(root, 2), direction: .left))
        #expect(root.description == "H[H[1, 2], 3]")
    }

    // 「下とまとめる」は横並びの中では「次の兄弟と縦のコンテナにまとめる」意味になる。
    // 方向が決めるのは**新しいコンテナの向き**と**どちらの隣を取るか**。
    @Test("方向に応じた向きのコンテナになる")
    func joinWithUsesDirectionOrientation() throws {
        let root = h(w(1), w(2))
        #expect(TreeOperations.joinWith(try node(root, 1), direction: .down))
        #expect(root.description == "H[V[1, 2]]")
    }

    @Test("新しいコンテナは2つの取り分を引き継ぐ")
    func joinWithInheritsCombinedWeight() throws {
        let root = h(w(1), w(2), w(3))
        root.setWeights([0.2, 0.3, 0.5])
        #expect(TreeOperations.joinWith(try node(root, 1), direction: .right))

        #expect(abs(root.weights[0] - 0.5) < 1e-9, "0.2 + 0.3 を引き継ぐ: \(root.weights)")
        #expect(abs(root.weights[1] - 0.5) < 1e-9, "残りの取り分は変わらない")

        let inner = try #require(root.children[0] as? ContainerNode)
        #expect(abs(inner.weights[0] - 0.4) < 1e-9, "中では 0.2:0.3 の比が保たれる: \(inner.weights)")
    }

    @Test("隣が無ければ何もしない")
    func joinWithDoesNothingWithoutNeighbor() throws {
        let root = h(w(1), w(2))
        #expect(!TreeOperations.joinWith(try node(root, 1), direction: .left))
        #expect(!TreeOperations.joinWith(try node(root, 2), direction: .right))
        #expect(root.description == "H[1, 2]")
    }

    @Test("まとめてもウィンドウを失わない")
    func joinWithPreservesAllWindows() throws {
        let root = h(w(1), w(2), w(3))
        #expect(TreeOperations.joinWith(try node(root, 1), direction: .right))
        Normalization.normalize(root)
        #expect(Set(root.windowIDs) == [1, 2, 3])
        #expect(root.invariantViolations().isEmpty)
    }

    // MARK: - layout（向きの巡回）

    @Test("候補の中で向きを巡回する")
    func cycleOrientationAdvances() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)

        #expect(TreeOperations.cycleOrientation(of: first, among: [.horizontal, .vertical]))
        #expect(root.orientation == .vertical)

        #expect(TreeOperations.cycleOrientation(of: first, among: [.horizontal, .vertical]))
        #expect(root.orientation == .horizontal)
    }

    @Test("候補に無い向きなら最初の候補にする")
    func cycleOrientationFallsBackToFirstCandidate() throws {
        let root = v(w(1), w(2))
        let first = try node(root, 1)

        #expect(TreeOperations.cycleOrientation(of: first, among: [.horizontal]))
        #expect(root.orientation == .horizontal)
    }

    @Test("変化しないなら false")
    func cycleOrientationReportsNoChange() throws {
        let root = h(w(1), w(2))
        let first = try node(root, 1)
        #expect(!TreeOperations.cycleOrientation(of: first, among: [.horizontal]))
    }

    // 正規化の「入れ子は親と逆向き」は自動で組まれた形を整えるための規則。
    // 利用者が明示的に選んだ向きをこれで戻すと、キーが効かないように見える。
    @Test("手で選んだ向きは正規化で戻されない")
    func explicitOrientationSurvivesNormalization() throws {
        let inner = v(w(2), w(3))
        let root = ContainerNode(orientation: .horizontal, children: [w(1), inner])
        let second = try node(root, 2)

        #expect(TreeOperations.cycleOrientation(of: second, among: [.horizontal, .vertical]))
        #expect(inner.orientation == .horizontal)
        #expect(inner.isOrientationExplicit)

        Normalization.normalize(root)
        #expect(inner.orientation == .horizontal, "親と同じ向きでも戻されない")
    }

    @Test("自動で組まれたコンテナの向きは正規化が整える")
    func implicitOrientationIsNormalized() {
        let root = h(w(1), h(w(2), w(3)))
        Normalization.normalize(root)
        #expect(root.description == "H[1, V[2, 3]]")
    }

    // MARK: - コマンド文字列のパース

    @Test("方向コマンドを解釈する")
    func parseDirectionalCommands() throws {
        #expect(try Command.parse("focus left") == .focus(.left))
        #expect(try Command.parse("focus down") == .focus(.down))
        #expect(try Command.parse("move up") == .move(.up))
        #expect(try Command.parse("move right") == .move(.right))
        #expect(try Command.parse("join-with down") == .joinWith(.down))
    }

    @Test("リサイズの符号を解釈する")
    func parseResize() throws {
        #expect(try Command.parse("resize width +50") == .resize(.width, delta: 50))
        #expect(try Command.parse("resize height -50") == .resize(.height, delta: -50))
        #expect(try Command.parse("resize width 50") == .resize(.width, delta: 50), "符号なしは増加")
    }

    @Test("layout の引数はそのまま並びで受ける")
    func parseLayout() throws {
        #expect(
            try Command.parse("layout tiles horizontal vertical")
                == .layout([.tiles, .horizontal, .vertical]))
        #expect(try Command.parse("layout floating tiling") == .layout([.floating, .tiling]))
    }

    @Test("余分な空白は無視する")
    func parseIgnoresExtraWhitespace() throws {
        #expect(try Command.parse("  focus   left  ") == .focus(.left))
    }

    @Test("不正なコマンドは診断できるエラーになる")
    func parseRejectsInvalidInput() {
        let invalid = [
            "", "focus", "focus sideways", "focus left right",
            "resize width", "resize depth +50", "resize width abc",
            "layout", "layout sideways", "frobnicate",
        ]
        for spec in invalid {
            #expect(throws: Command.ParseError.self, "\"\(spec)\"") {
                try Command.parse(spec)
            }
        }
    }

    // 未対応のコマンドは「知っているが未対応」と伝える。設定に書いてあるのに
    // 黙って無視されると、キーが効かない原因が設定側か実装側か分からない。
    @Test("引数を取らないコマンドを解釈する")
    func parseArgumentlessCommands() throws {
        #expect(try Command.parse("close-window") == .closeWindow)
        #expect(try Command.parse("reload-config") == .reloadConfig)
        #expect(throws: Command.ParseError.self) { try Command.parse("close-window now") }
        #expect(throws: Command.ParseError.self) { try Command.parse("reload-config all") }
    }

    @Test("ワークスペースのコマンドを解釈する")
    func parseWorkspaceCommands() throws {
        #expect(try Command.parse("workspace 1") == .workspace(.index(1)))
        #expect(try Command.parse("workspace 10") == .workspace(.index(10)))
        #expect(try Command.parse("workspace back-and-forth") == .workspace(.backAndForth))
        #expect(try Command.parse("move-node-to-workspace 3") == .moveNodeToWorkspace(.index(3)))
    }

    @Test("ワークスペース番号は 1 以上でなければならない")
    func parseRejectsInvalidWorkspaceNumbers() {
        for spec in ["workspace 0", "workspace -1", "workspace abc", "workspace", "workspace 1 2",
                    "move-node-to-workspace 0", "move-node-to-workspace"] {
            #expect(throws: Command.ParseError.self, "\"\(spec)\"") {
                try Command.parse(spec)
            }
        }
    }

    @Test("コマンドは設定に書ける綴りへ戻せる")
    func commandRoundTripsThroughItsDescription() throws {
        let specs = [
            "focus left", "move down", "resize width +50", "resize height -50",
            "join-with right", "layout tiles horizontal vertical", "layout floating tiling",
            "workspace 3", "workspace back-and-forth", "move-node-to-workspace 7",
            "close-window", "reload-config", "fullscreen",
            "workspace next", "workspace prev",
            "move-node-to-workspace next", "move-node-to-workspace prev",
            "move-node-to-workspace back-and-forth",
            "exec open -a Terminal", "flatten-workspace-tree",
            "focus parent", "focus child", "focus mode-toggle",
            "split horizontal", "split vertical", "split opposite",
        ]
        for spec in specs {
            let command = try Command.parse(spec)
            #expect(command.description == spec, "\(command)")
            #expect(try Command.parse(command.description) == command)
        }
    }

    @Test("未実装のコマンドは未対応として区別できる")
    func parseReportsUnsupportedCommands() {
        // 実装したものはここから外すこと。**残っているのは macOS のネイティブ機能に
        // 寄せたものと、comet の設計と噛み合わないものだけ。**
        for spec in [
            "macos-native-fullscreen", "macos-native-minimize", "summon-workspace 3",
            "volume up", "enable toggle", "trigger-binding a", "debug-windows",
        ] {
            let name = String(spec.split(separator: " ")[0])
            #expect(throws: Command.ParseError.unsupported(name: name), "\"\(spec)\"") {
                try Command.parse(spec)
            }
        }
        #expect(
            Command.ParseError.unsupported(name: "macos-native-fullscreen")
                .description.contains("未対応"))
        // 綴りだけ受けて実装の無い layout の引数も未対応として伝える。
        // 黙って受けると、押しても「向きが無い」と言われるだけで原因が分からない。
        #expect(throws: Command.ParseError.unsupported(name: "layout accordion")) {
            try Command.parse("layout accordion")
        }
    }

    @Test("layout の引数から向きの候補を取り出せる")
    func layoutArgumentsExposeOrientations() {
        #expect(
            [LayoutArgument.tiles, .horizontal, .vertical].orientations == [.horizontal, .vertical])
        #expect([LayoutArgument.floating, .tiling].orientations.isEmpty)
        #expect([LayoutArgument.floating, .tiling].togglesFloating)
        #expect(![LayoutArgument.tiles, .horizontal].togglesFloating)
    }
}
