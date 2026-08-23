import CoreGraphics
import Foundation
import Testing
import CometCore

/// 分割の比率を均等に戻す（AeroSpace の `balance-sizes`）。
@Suite("比率を均等に戻す")
struct BalanceSizesTests {

    private func h(_ children: Node...) -> ContainerNode {
        let container = ContainerNode(orientation: .horizontal)
        children.forEach { container.append($0) }
        return container
    }
    private func v(_ children: Node...) -> ContainerNode {
        let container = ContainerNode(orientation: .vertical)
        children.forEach { container.append($0) }
        return container
    }
    private func w(_ id: CGWindowID) -> WindowNode { WindowNode(id) }

    @Test("偏った比率を均等に戻す")
    func evensOutWeights() {
        let root = h(w(1), w(2), w(3))
        root.setWeights([0.7, 0.2, 0.1])

        #expect(TreeOperations.balance(root))
        for weight in root.weights {
            #expect(abs(weight - 1.0 / 3) < 1e-9)
        }
    }

    @Test("入れ子の中まで均等にする")
    func reachesNestedContainers() {
        let nested = v(w(2), w(3))
        nested.setWeights([0.9, 0.1])
        let root = h(w(1), nested)
        root.setWeights([0.8, 0.2])

        #expect(TreeOperations.balance(root))
        #expect(abs(root.weights[0] - 0.5) < 1e-9)
        #expect(abs(nested.weights[0] - 0.5) < 1e-9)
    }

    // 一段だけ均すと見た目には偏りが残り「効かない」と読まれる。
    @Test("葉を渡したら親コンテナを均す")
    func aLeafBalancesItsParent() {
        let root = h(w(1), w(2))
        root.setWeights([0.9, 0.1])
        let leaf = root.findWindow(1)
        #expect(leaf != nil)

        #expect(TreeOperations.balance(leaf!))
        #expect(abs(root.weights[0] - 0.5) < 1e-9)
    }

    @Test("既に均等なら何も変えない")
    func alreadyEvenIsUntouched() {
        let root = h(w(1), w(2), w(3))
        #expect(!TreeOperations.balance(root), "再配置を省けるように false を返す")
    }

    @Test("子が1つ以下でも落ちない")
    func handlesSmallTrees() {
        #expect(!TreeOperations.balance(ContainerNode(orientation: .horizontal)))
        #expect(!TreeOperations.balance(h(w(1))))
    }

    @Test("コマンドとして解釈できる")
    func parsesCommand() throws {
        #expect(try Command.parse("balance-sizes") == .balanceSizes)
        #expect(Command.balanceSizes.description == "balance-sizes")
        #expect(throws: Command.ParseError.self) { try Command.parse("balance-sizes all") }
    }
}

/// 終了・マウス・ワークスペースの往復など、単発のコマンドの綴り。
@Suite("単発のコマンドの綴り")
struct MiscCommandTests {

    @Test("終了を i3 の綴りで書ける")
    func parsesExit() throws {
        #expect(try Command.parse("exit") == .exit)
        #expect(try Command.parse("quit") == .exit)
        #expect(Command.exit.description == "exit")
        #expect(throws: Command.ParseError.self) { try Command.parse("exit now") }
    }

    @Test("マウスポインタの移動先を解釈する")
    func parsesMoveMouse() throws {
        #expect(try Command.parse("move-mouse window-lazy-center") == .moveMouse(.windowLazyCenter))
        #expect(
            try Command.parse("move-mouse monitor-force-center") == .moveMouse(.monitorForceCenter))
        #expect(throws: Command.ParseError.self) { try Command.parse("move-mouse center") }
        #expect(throws: Command.ParseError.self) { try Command.parse("move-mouse") }
    }

    @Test("マウスの指定は狙いと横着を表す")
    func mouseTargetProperties() {
        #expect(MouseTarget.windowLazyCenter.isWindow)
        #expect(MouseTarget.windowLazyCenter.isLazy)
        #expect(!MouseTarget.monitorForceCenter.isWindow)
        #expect(!MouseTarget.monitorForceCenter.isLazy)
    }

    // AeroSpace の綴り。comet では `workspace back-and-forth` と同じ。
    @Test("workspace-back-and-forth は往復として読む")
    func parsesAeroSpaceBackAndForth() throws {
        #expect(try Command.parse("workspace-back-and-forth") == .workspace(.backAndForth))
    }

    @Test("i3 の resize grow / shrink を解釈する")
    func parsesI3Resize() throws {
        #expect(try Command.parse("resize grow width 50 px") == .resize(.width, delta: 50))
        #expect(try Command.parse("resize shrink height 30 px") == .resize(.height, delta: -30))
        // 単位の綴りは省いても通る。
        #expect(try Command.parse("resize grow width 10") == .resize(.width, delta: 10))
        // `or 10 ppt` の後半は落とす（comet は点数で受ける）。
        #expect(
            try Command.parse("resize grow width 10 px or 5 ppt") == .resize(.width, delta: 10))
        // 方向で書かれたものは寸法へ読み替える。
        #expect(try Command.parse("resize grow left 25 px") == .resize(.width, delta: 25))
        #expect(try Command.parse("resize shrink up 25 px") == .resize(.height, delta: -25))
    }

    @Test("読めない resize は誤りとして扱う")
    func rejectsUnreadableResize() {
        #expect(throws: Command.ParseError.self) { try Command.parse("resize grow sideways 10") }
        #expect(throws: Command.ParseError.self) { try Command.parse("resize grow width wide") }
        #expect(throws: Command.ParseError.self) { try Command.parse("resize grow width") }
    }
}

/// 押しっぱなしで繰り返してよいコマンドの判断。
///
/// **`move` や `workspace` を繰り返すとウィンドウが飛んでいって収拾がつかない。**
/// 逆に `resize` と `focus` は繰り返さないと i3 に比べて明確に鈍い。
@Suite("繰り返しの対象")
struct RepeatPolicyTests {

    private let base: TimeInterval = 0.03
    private let focus: TimeInterval = 0.12

    @Test("resize は設定どおりの速さで繰り返す")
    func resizeUsesTheConfiguredInterval() {
        let commands: [Command] = [.resize(.width, delta: 50)]
        #expect(commands.repeatInterval(base: base, focus: focus) == base)
    }

    // 1回ごとにアプリの前面化を伴うので、resize と同じ速さでは追いつかない。
    @Test("方向フォーカスは緩めて繰り返す")
    func focusIsSlower() {
        let commands: [Command] = [.focus(.right)]
        #expect(commands.repeatInterval(base: base, focus: focus) == focus)
    }

    @Test("設定でさらに遅くしているならそちらを尊重する")
    func aSlowerConfigurationWins() {
        let commands: [Command] = [.focus(.right)]
        #expect(commands.repeatInterval(base: 0.4, focus: focus) == 0.4)
    }

    @Test("resize と focus が混ざったら速いほうに合わせる")
    func mixedFallsBackToTheBase() {
        let commands: [Command] = [.focus(.right), .resize(.width, delta: 10)]
        #expect(commands.repeatInterval(base: base, focus: focus) == base)
    }

    @Test("それ以外は繰り返さない")
    func othersDoNotRepeat() {
        #expect([Command.move(.left)].repeatInterval(base: base, focus: focus) == nil)
        #expect([Command.workspace(.next)].repeatInterval(base: base, focus: focus) == nil)
        #expect([Command.closeWindow].repeatInterval(base: base, focus: focus) == nil)
        #expect(
            [Command.focus(.right), .closeWindow].repeatInterval(base: base, focus: focus) == nil,
            "1つでも危ないものが混ざれば繰り返さない")
        #expect([Command]().repeatInterval(base: base, focus: focus) == nil)
    }
}
