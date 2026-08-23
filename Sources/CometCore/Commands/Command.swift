import CoreGraphics
import Foundation

/// リサイズの対象となる寸法。
public enum Dimension: String, Sendable, Equatable, CaseIterable {
    case width
    case height

    public var orientation: Orientation {
        self == .width ? .horizontal : .vertical
    }
}

/// `layout` コマンドの引数。AeroSpace の綴りをそのまま受ける。
public enum LayoutArgument: String, Sendable, Equatable, CaseIterable {
    case tiles
    case horizontal
    case vertical
    case floating
    case tiling
    /// AeroSpace 互換のために受けるが、comet では未対応。
    case accordion
}

extension Array where Element == LayoutArgument {

    /// 巡回の候補になる向き。並びは書かれた順。
    public var orientations: [Orientation] {
        compactMap {
            switch $0 {
            case .horizontal: .horizontal
            case .vertical: .vertical
            default: nil
            }
        }
    }

    /// フローティングとタイルの切り替えを指しているか。
    public var togglesFloating: Bool {
        contains(.floating) || contains(.tiling)
    }
}

extension Array where Element == Command {

    /// 押しっぱなしで繰り返すときの間隔。**`nil` なら繰り返さない。**
    ///
    /// 繰り返すのは **`resize` と方向フォーカスだけ**。
    ///
    /// - `resize` は境界を少しずつ動かすものなので、押しっぱなしで追従しないと使えない。
    /// - `focus` は端で止まる（巻き戻らない）ので、連射しても行き過ぎない。
    ///   i3 は X11 のキー連射でこれが効くため、無いと明確に鈍く感じる。
    ///   ただし **1回ごとにアプリの前面化を伴う**ので、`resize` と同じ速さでは
    ///   macOS 側が追いつかず、押した数だけ画面が入れ替わり続ける。間隔を分ける。
    ///
    /// `move` と `workspace` は繰り返さない。連射されるとウィンドウが飛んでいって
    /// 収拾がつかず、どこへ行ったか分からなくなる。
    ///
    /// - Parameters:
    ///   - base: 設定で指定された間隔。`resize` にはこれを使う。
    ///   - focus: 方向フォーカスの間隔。`base` がこれより遅ければ `base` を尊重する。
    public func repeatInterval(base: TimeInterval, focus: TimeInterval) -> TimeInterval? {
        guard !isEmpty else { return nil }
        var isFocusOnly = true
        for command in self {
            switch command {
            case .resize: isFocusOnly = false
            case .focus: break
            default: return nil
            }
        }
        return isFocusOnly ? Swift.max(base, focus) : base
    }
}

/// `workspace` コマンドの行き先。
public enum WorkspaceTarget: Equatable, Sendable {
    case index(WorkspaceID)
    /// 直前のワークスペースへ戻る。続けて押すと2つの間を往復する。
    case backAndForth
    /// 番号順に次へ。**端では巻き戻る**（i3 の `workspace next` と同じ）。
    case next
    /// 番号順に前へ。端では巻き戻る。
    case previous
}

/// モニタの指定（i3 の output）。
///
/// `next` / `prev` は**並び順で巻き戻る**。`left` / `right` は幾何的に隣を指し、
/// **端では動かない**（i3 の方向指定と同じ）。
public enum MonitorTarget: String, Sendable, Equatable, CaseIterable {
    case next
    case previous = "prev"
    /// メインディスプレイ（メニューバーのある画面）。
    case main
    case left
    case right
}

/// `focus floating` / `focus tiling` / `focus mode_toggle`。**層を選ぶ。**
///
/// i3 の綴りをそのまま受ける。`mode_toggle` は往復、他は片方向。
public enum FocusLayer: String, Sendable, Equatable, CaseIterable {
    /// 浮いているウィンドウへ。
    case floating
    /// 並んでいるウィンドウへ。
    case tiling
    /// 今と違う層へ（往復）。
    case toggle

    /// 行き先が浮いている側か。`toggle` は今の状態から決めるので `nil`。
    public var wantsFloating: Bool? {
        switch self {
        case .floating: true
        case .tiling: false
        case .toggle: nil
        }
    }
}

/// `focus parent` / `focus child`。**コンテナを選ぶための上下移動。**
///
/// i3 では、入れ子のコンテナごと動かしたり向きを変えたりするのにこれが要る。
/// `move` や `resize` や `layout` の対象が「ウィンドウ」から「そのコンテナ」に変わる。
public enum ContainerFocus: String, Sendable, Equatable, CaseIterable {
    case parent
    case child
}

/// `split` コマンドの向き。**次に開くウィンドウの入り方**を決める。
///
/// i3 の `split h` / `split v` / `split toggle` に相当する。
public enum SplitTarget: String, Sendable, Equatable, CaseIterable {
    case horizontal
    case vertical
    /// 今フォーカスしているコンテナの向きの逆（i3 の `split toggle`）。
    case opposite
}

/// `enable` / `disable` / `toggle` の3値（i3 の綴りをそのまま受ける）。
///
/// **`toggle` を既定にする。** 引数なしの `fullscreen` は i3 でも切り替えなので、
/// 綴りを省いたときに驚かない。
public enum Toggle: String, Sendable, Equatable, CaseIterable {
    case on = "enable"
    case off = "disable"
    case toggle

    /// 今の状態から次の状態を決める。
    public func resolve(current: Bool) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .toggle: !current
        }
    }
}

/// `move position` の行き先（i3 の `move position center`）。
public enum MovePosition: String, Sendable, Equatable, CaseIterable {
    /// 今のモニタの中央へ。**フローティングのウィンドウだけが対象。**
    case center
}

/// マウスポインタの移動先（AeroSpace の `move-mouse`）。
///
/// `lazy` は**既にその範囲の中に居るなら動かさない**。動かすとポインタが
/// 勝手に飛ぶので、必要なときだけにする。
public enum MouseTarget: String, Sendable, Equatable, CaseIterable {
    case windowLazyCenter = "window-lazy-center"
    case windowForceCenter = "window-force-center"
    case monitorLazyCenter = "monitor-lazy-center"
    case monitorForceCenter = "monitor-force-center"

    /// ウィンドウを狙うか（false ならモニタ）。
    public var isWindow: Bool {
        self == .windowLazyCenter || self == .windowForceCenter
    }
    /// 既に範囲の中に居るなら動かさないか。
    public var isLazy: Bool {
        self == .windowLazyCenter || self == .monitorLazyCenter
    }
}

/// `gaps` コマンド（i3-gaps の綴り）。
///
/// comet の間隔は**全ワークスペース共通**なので、`current` と `all` は同じ意味になる。
/// 綴りは受けて、効き方が違わないことを説明で伝える。
public struct GapsChange: Sendable, Equatable {

    /// どの間隔を変えるか。
    public enum Field: String, Sendable, Equatable, CaseIterable {
        /// 内側（アプリ間）の両方向。
        case inner
        /// 外周の四辺。
        case outer
        /// 内側の横方向だけ。
        case horizontal
        /// 内側の縦方向だけ。
        case vertical
        case top
        case bottom
        case left
        case right
    }

    public enum Operation: String, Sendable, Equatable, CaseIterable {
        case set
        case plus
        case minus
    }

    public let field: Field
    public let operation: Operation
    public let value: CGFloat

    public init(field: Field, operation: Operation, value: CGFloat) {
        self.field = field
        self.operation = operation
        self.value = value
    }

    /// 変更を適用した間隔を返す。**負にはしない**（境界が領域の外へ出てウィンドウが重なる）。
    public func applied(to gaps: Gaps) -> Gaps {
        var result = gaps
        func next(_ current: CGFloat) -> CGFloat {
            switch operation {
            case .set: max(0, value)
            case .plus: max(0, current + value)
            case .minus: max(0, current - value)
            }
        }
        switch field {
        case .inner:
            result.innerHorizontal = next(gaps.innerHorizontal)
            result.innerVertical = next(gaps.innerVertical)
        case .horizontal:
            result.innerHorizontal = next(gaps.innerHorizontal)
        case .vertical:
            result.innerVertical = next(gaps.innerVertical)
        case .outer:
            result.outerTop = next(gaps.outerTop)
            result.outerBottom = next(gaps.outerBottom)
            result.outerLeft = next(gaps.outerLeft)
            result.outerRight = next(gaps.outerRight)
        case .top:
            result.outerTop = next(gaps.outerTop)
        case .bottom:
            result.outerBottom = next(gaps.outerBottom)
        case .left:
            result.outerLeft = next(gaps.outerLeft)
        case .right:
            result.outerRight = next(gaps.outerRight)
        }
        return result
    }
}

/// ホットキーから実行される操作。**文字列表現は AeroSpace 互換**にしてある。
///
/// 互換にしておくと、現行の AeroSpace 設定をほぼそのまま持ってこられる。
public enum Command: Equatable, Sendable, CustomStringConvertible {

    case focus(Direction)
    /// アプリ巡回・アプリ内のウィンドウ巡回（Hammerspoon の Alt+F / Alt+D 相当）。
    case focusCycle(FocusCycleTarget)
    case move(Direction)
    /// 点数を指定した移動（i3 の `move left 40 px`）。
    ///
    /// **効くのはフローティングのウィンドウだけ。** タイルのウィンドウは列の中で
    /// 入れ替わるので点数の意味が無く、i3 も点数を無視して `move` と同じ動きになる。
    case moveBy(Direction, points: CGFloat)
    /// フローティングのウィンドウを決まった位置へ（i3 の `move position center`）。
    case movePosition(MovePosition)
    case resize(Dimension, delta: CGFloat)
    /// 分割の比率を均等に戻す（AeroSpace の `balance-sizes`）。
    ///
    /// リサイズを重ねて収拾がつかなくなったときの戻し先。`focus parent` で
    /// コンテナを選んでいればその中だけ、選んでいなければワークスペース全体。
    case balanceSizes
    /// 間隔を変える（i3-gaps の `gaps`）。
    ///
    /// **設定を書き換えるわけではない。** 読み直すと設定ファイルの値に戻る。
    case gaps(GapsChange)
    /// マウスポインタを動かす（AeroSpace の `move-mouse`）。
    case moveMouse(MouseTarget)
    case joinWith(Direction)
    /// 引数を順に巡回して次の状態にする（`layout tiles horizontal vertical` など）。
    case layout([LayoutArgument])
    case workspace(WorkspaceTarget)
    /// フォーカス中のウィンドウを別のワークスペースへ移す。表示は切り替えない。
    case moveNodeToWorkspace(WorkspaceTarget)
    /// フォーカス中のウィンドウを閉じる。
    case closeWindow
    /// 設定を読み直す。**ツリーの形は保つ。**
    case reloadConfig
    /// フォーカス中のウィンドウを領域いっぱいに広げる／戻す。
    ///
    /// macOS のネイティブフルスクリーンではない。あれは専用の操作スペースを作るため
    /// ワークスペースの実装と衝突する。ここではタイル配置の中で1枚だけ広げる。
    case fullscreen(Toggle)
    /// タイルとフローティングを切り替える（i3 の `floating enable|disable|toggle`）。
    ///
    /// `layout floating tiling` と同じことを、明示的な on/off でも書けるようにする。
    case floating(Toggle)
    /// comet を終了する（i3 の `exit`）。
    ///
    /// **退避したウィンドウを画面へ戻し、隠したアプリを表示に戻してから**終わる。
    case exit
    /// シェルへ渡して実行する。**待たない。**
    ///
    /// i3 の `exec`（AeroSpace の `exec-and-forget`）。`$mod+Return` でターミナルを
    /// 開くような使い方が i3 の基本操作なので、これが無いと常用の起点が作れない。
    case exec(String)
    /// 入れ子を全部ほどいて、ウィンドウをルート直下に並べ直す。
    case flattenWorkspaceTree
    /// コンテナを選ぶ上下移動（i3 の `focus parent` / `focus child`）。
    case focusContainer(ContainerFocus)
    /// タイルとフローティングの間でフォーカスを移す
    ///（i3 の `focus mode_toggle` / `focus floating` / `focus tiling`）。
    case focusLayer(FocusLayer)
    /// 次に開くウィンドウの入り方を決める（i3 の `split h` / `split v`）。
    case split(SplitTarget)
    /// 別のモニタへフォーカスを移す（i3 の `focus output`）。
    case focusMonitor(MonitorTarget)
    /// フォーカス中のウィンドウを別のモニタへ移す（i3 の `move container to output`）。
    case moveNodeToMonitor(MonitorTarget)
    /// 今のワークスペースを別のモニタへ移す（i3 の `move workspace to output`）。
    case moveWorkspaceToMonitor(MonitorTarget)
    /// キーの層を切り替える（i3 の `mode "resize"`）。
    ///
    /// 層の中では**修飾キーなしのキーも奪う**。それがモードの目的で、
    /// `h` だけでリサイズできるようになる。抜けるキーを必ず用意すること
    ///（用意し忘れても `esc` で戻れるようにしてある）。
    case mode(String)

    /// 設定に書ける綴りへ戻す。ログで「どのコマンドが動いたか」を追えるようにする。
    public var description: String {
        switch self {
        case .focus(let direction): "focus \(direction.rawValue)"
        case .focusCycle(let target): "focus \(target.rawValue)"
        case .move(let direction): "move \(direction.rawValue)"
        case .moveBy(let direction, let points):
            "move \(direction.rawValue) \(Int(points)) px"
        case .movePosition(let position): "move position \(position.rawValue)"
        case .balanceSizes: "balance-sizes"
        case .moveMouse(let target): "move-mouse \(target.rawValue)"
        case .gaps(let change):
            "gaps \(change.field.rawValue) all \(change.operation.rawValue) \(Int(change.value))"
        case .joinWith(let direction): "join-with \(direction.rawValue)"
        case .resize(let dimension, let delta):
            "resize \(dimension.rawValue) \(delta < 0 ? "" : "+")\(Int(delta))"
        case .layout(let arguments):
            "layout \(arguments.map(\.rawValue).joined(separator: " "))"
        case .workspace(.index(let id)):
            "workspace \(id)"
        case .workspace(.backAndForth):
            "workspace back-and-forth"
        case .moveNodeToWorkspace(.index(let id)):
            "move-node-to-workspace \(id)"
        case .moveNodeToWorkspace(.backAndForth):
            "move-node-to-workspace back-and-forth"
        case .moveNodeToWorkspace(.next):
            "move-node-to-workspace next"
        case .moveNodeToWorkspace(.previous):
            "move-node-to-workspace prev"
        case .workspace(.next): "workspace next"
        case .workspace(.previous): "workspace prev"
        case .closeWindow: "close-window"
        case .reloadConfig: "reload-config"
        case .fullscreen(.toggle): "fullscreen"
        case .fullscreen(let toggle): "fullscreen \(toggle.rawValue)"
        case .floating(let toggle): "floating \(toggle.rawValue)"
        case .exit: "exit"
        case .exec(let line): "exec \(line)"
        case .flattenWorkspaceTree: "flatten-workspace-tree"
        case .focusContainer(let target): "focus \(target.rawValue)"
        case .focusLayer(.toggle): "focus mode-toggle"
        case .focusLayer(let layer): "focus \(layer.rawValue)"
        case .split(let target): "split \(target.rawValue)"
        case .focusMonitor(let target): "focus-monitor \(target.rawValue)"
        case .moveNodeToMonitor(let target): "move-node-to-monitor \(target.rawValue)"
        case .moveWorkspaceToMonitor(let target):
            "move-workspace-to-monitor \(target.rawValue)"
        case .mode(let name): "mode \(name)"
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknown(name: String)
        /// 綴りは知っているが、まだ実装していないコマンド。
        case unsupported(name: String)
        case wrongArgumentCount(name: String, expected: String, got: Int)
        case invalidArgument(name: String, argument: String)

        public var description: String {
            switch self {
            case .empty:
                "コマンドが空"
            case .unknown(let name):
                "不明なコマンド: \(name)"
            case .unsupported(let name):
                "\(name) はまだ未対応（後続の Phase で実装する）"
            case .wrongArgumentCount(let name, let expected, let got):
                "\(name) の引数は \(expected) 個だが \(got) 個だった"
            case .invalidArgument(let name, let argument):
                "\(name) の引数として解釈できない: \(argument)"
            }
        }
    }

    /// 綴りは知っているが comet には無いコマンド。
    ///
    /// **「不明」と分けておかないと、綴り間違いなのか未実装なのかが区別できない。**
    /// AeroSpace の設定をそのまま持ってきた人が、どの行が効かないのかを
    /// 起動時のログで確かめられるようにする。
    private static let plannedCommands: Set<String> = [
        "macos-native-fullscreen", "macos-native-minimize",
        "summon-workspace", "volume", "enable", "trigger-binding",
        "debug-windows",
    ]

    public static func parse(_ text: String) throws -> Command {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = tokens.first else { throw ParseError.empty }
        let arguments = Array(tokens.dropFirst())

        // **exec は引数を分解しない。** シェルへ渡す1行なので、空白も引用符も
        // 書いたままでなければ意味が変わる。
        if name == "exec" || name == "exec-and-forget" {
            let line = text.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                throw ParseError.wrongArgumentCount(name: name, expected: "1 以上", got: 0)
            }
            return .exec(line)
        }

        switch name {
        case "focus":
            // 方向（left/down/up/right）・巡回（next-app 等）・階層（parent/child）を受ける。
            if arguments.count == 1, let target = FocusCycleTarget(rawValue: arguments[0]) {
                return .focusCycle(target)
            }
            if arguments.count == 1, let target = ContainerFocus(rawValue: arguments[0]) {
                return .focusContainer(target)
            }
            // i3 の綴りは mode_toggle。comet の綴りに合わせた形も受ける。
            if arguments == ["mode_toggle"] || arguments == ["mode-toggle"] {
                return .focusLayer(.toggle)
            }
            // i3 の `focus floating` / `focus tiling`。層を直に指す。
            if arguments.count == 1, let layer = FocusLayer(rawValue: arguments[0]),
                layer != .toggle
            {
                return .focusLayer(layer)
            }
            // i3 の `focus output <target>`。
            if arguments.count == 2, arguments[0] == "output" {
                return .focusMonitor(try parseMonitor(name, [arguments[1]]))
            }
            return .focus(try parseDirection(name, arguments))
        case "mode":
            guard arguments.count == 1 else {
                throw ParseError.wrongArgumentCount(
                    name: name, expected: "1", got: arguments.count)
            }
            // i3 は `mode "resize"` と引用符付きで書く。TOML の値としては
            // 引用符が外れているが、`mode "resize"` と書き写されても通す。
            let mode = arguments[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !mode.isEmpty else {
                throw ParseError.invalidArgument(name: name, argument: arguments[0])
            }
            return .mode(mode)
        case "focus-monitor":
            return .focusMonitor(try parseMonitor(name, arguments))
        case "move-node-to-monitor":
            return .moveNodeToMonitor(try parseMonitor(name, arguments))
        case "move-workspace-to-monitor":
            return .moveWorkspaceToMonitor(try parseMonitor(name, arguments))
        case "split":
            return .split(try parseSplit(arguments))
        case "flatten-workspace-tree":
            return try noArguments(name, arguments, .flattenWorkspaceTree)
        case "move":
            // i3 の長い綴り。`move container to output right` / `move workspace to output right`。
            if arguments.count == 4, arguments[1] == "to", arguments[2] == "output" {
                let target = try parseMonitor(name, [arguments[3]])
                switch arguments[0] {
                case "container", "window": return .moveNodeToMonitor(target)
                case "workspace": return .moveWorkspaceToMonitor(target)
                default: throw ParseError.invalidArgument(name: name, argument: arguments[0])
                }
            }
            // i3 の `move container to workspace N`。
            if arguments.count == 4, arguments[1] == "to", arguments[2] == "workspace",
                arguments[0] == "container" || arguments[0] == "window"
            {
                return .moveNodeToWorkspace(try parseWorkspaceTarget([arguments[3]], name: name))
            }
            // i3 の `move position center`。フローティングのウィンドウを中央へ。
            if arguments.count == 2, arguments[0] == "position" {
                guard let position = MovePosition(rawValue: arguments[1]) else {
                    throw ParseError.invalidArgument(name: name, argument: arguments[1])
                }
                return .movePosition(position)
            }
            // i3 の `move left 40 px`。**点数はフローティングのときだけ効く。**
            // 単位の綴り（px）は付いていても付いていなくても受ける。
            if arguments.count == 2 || (arguments.count == 3 && arguments[2] == "px") {
                let direction = try parseDirection(name, [arguments[0]])
                guard let points = Double(arguments[1]), points.isFinite else {
                    throw ParseError.invalidArgument(name: name, argument: arguments[1])
                }
                return .moveBy(direction, points: CGFloat(points))
            }
            return .move(try parseDirection(name, arguments))
        case "move-mouse":
            guard arguments.count == 1 else {
                throw ParseError.wrongArgumentCount(
                    name: name, expected: "1", got: arguments.count)
            }
            guard let target = MouseTarget(rawValue: arguments[0]) else {
                throw ParseError.invalidArgument(name: name, argument: arguments[0])
            }
            return .moveMouse(target)
        case "balance-sizes":
            return try noArguments(name, arguments, .balanceSizes)
        case "gaps":
            return .gaps(try parseGaps(arguments))
        case "floating":
            guard arguments.count == 1 else {
                throw ParseError.wrongArgumentCount(
                    name: name, expected: "1", got: arguments.count)
            }
            guard let toggle = Toggle(rawValue: arguments[0]) else {
                throw ParseError.invalidArgument(name: name, argument: arguments[0])
            }
            return .floating(toggle)
        // i3 の綴り。`quit` は指が覚えているほうでも通るようにする。
        case "exit", "quit":
            return try noArguments(name, arguments, .exit)
        // AeroSpace の綴り。comet では `workspace back-and-forth` と同じ。
        case "workspace-back-and-forth":
            return try noArguments(name, arguments, .workspace(.backAndForth))
        case "join-with":
            return .joinWith(try parseDirection(name, arguments))
        case "resize":
            return try parseResize(arguments)
        case "layout":
            return try parseLayout(arguments)
        case "workspace":
            return .workspace(try parseWorkspaceTarget(arguments, name: name))
        case "move-node-to-workspace":
            return .moveNodeToWorkspace(try parseWorkspaceTarget(arguments, name: name))
        // `kill` と `reload` は i3 の綴り。指が覚えているほうでも通るようにする。
        case "close-window", "kill":
            return try noArguments(name, arguments, .closeWindow)
        case "reload-config", "reload":
            return try noArguments(name, arguments, .reloadConfig)
        case "fullscreen":
            // i3 は `fullscreen toggle` と書く。引数なしも切り替えとして受ける。
            // `global` は付いていても無視する（comet の全画面は常にそのモニタの中）。
            let flags = arguments.filter { $0 != "global" }
            if flags.isEmpty { return .fullscreen(.toggle) }
            guard flags.count == 1, let toggle = Toggle(rawValue: flags[0]) else {
                throw ParseError.invalidArgument(
                    name: name, argument: arguments.joined(separator: " "))
            }
            return .fullscreen(toggle)
        default:
            throw plannedCommands.contains(name)
                ? ParseError.unsupported(name: name)
                : ParseError.unknown(name: name)
        }
    }

    private static func noArguments(
        _ name: String, _ arguments: [String], _ command: Command
    ) throws -> Command {
        guard arguments.isEmpty else {
            throw ParseError.wrongArgumentCount(name: name, expected: "0", got: arguments.count)
        }
        return command
    }

    private static func parseDirection(_ name: String, _ arguments: [String]) throws -> Direction {
        guard arguments.count == 1 else {
            throw ParseError.wrongArgumentCount(name: name, expected: "1", got: arguments.count)
        }
        guard let direction = Direction(rawValue: arguments[0]) else {
            throw ParseError.invalidArgument(name: name, argument: arguments[0])
        }
        return direction
    }

    /// i3 の `resize grow|shrink <方向|寸法> <n> [px] [or <n> ppt]` を受ける。
    ///
    /// 方向指定（`grow left`）は寸法へ読み替える。comet が変えられるのは分割の
    /// 境界なので、「左へ広げる」も「幅を増やす」と同じ操作になる。
    private static func parseI3Resize(_ arguments: [String]) throws -> Command {
        let isGrow = arguments[0] == "grow"
        // `or 10 ppt` の後半は落とす。comet は比率ではなく点数で受ける。
        var rest = Array(arguments.dropFirst())
        if let orIndex = rest.firstIndex(of: "or") {
            rest = Array(rest[..<orIndex])
        }
        guard rest.count >= 2 else {
            throw ParseError.wrongArgumentCount(
                name: "resize", expected: "3 以上", got: arguments.count)
        }
        let dimension: Dimension
        if let value = Dimension(rawValue: rest[0]) {
            dimension = value
        } else if let direction = Direction(rawValue: rest[0]) {
            dimension = direction.orientation == .horizontal ? .width : .height
        } else {
            throw ParseError.invalidArgument(name: "resize", argument: rest[0])
        }
        guard let magnitude = Double(rest[1]), magnitude.isFinite else {
            throw ParseError.invalidArgument(name: "resize", argument: rest[1])
        }
        return .resize(dimension, delta: CGFloat(isGrow ? magnitude : -magnitude))
    }

    private static func parseGaps(_ arguments: [String]) throws -> GapsChange {
        // i3-gaps は `gaps inner current set 10`。範囲（current / all）は
        // comet では意味を持たないので、書いてあれば読み飛ばす。
        let tokens = arguments.filter { $0 != "current" && $0 != "all" }
        guard tokens.count == 3 else {
            throw ParseError.wrongArgumentCount(
                name: "gaps", expected: "3", got: arguments.count)
        }
        guard let field = GapsChange.Field(rawValue: tokens[0]) else {
            throw ParseError.invalidArgument(name: "gaps", argument: tokens[0])
        }
        guard let operation = GapsChange.Operation(rawValue: tokens[1]) else {
            throw ParseError.invalidArgument(name: "gaps", argument: tokens[1])
        }
        guard let value = Double(tokens[2]), value.isFinite else {
            throw ParseError.invalidArgument(name: "gaps", argument: tokens[2])
        }
        return GapsChange(field: field, operation: operation, value: CGFloat(value))
    }

    private static func parseResize(_ arguments: [String]) throws -> Command {
        if arguments.first == "grow" || arguments.first == "shrink" {
            return try parseI3Resize(arguments)
        }
        guard arguments.count == 2 else {
            throw ParseError.wrongArgumentCount(name: "resize", expected: "2", got: arguments.count)
        }
        guard let dimension = Dimension(rawValue: arguments[0]) else {
            throw ParseError.invalidArgument(name: "resize", argument: arguments[0])
        }

        // AeroSpace は "+50" / "-50" / "50" を受ける。符号なしは増加。
        let raw = arguments[1]
        let isNegative = raw.hasPrefix("-")
        let magnitude = isNegative || raw.hasPrefix("+") ? String(raw.dropFirst()) : raw
        guard let value = Double(magnitude), value.isFinite else {
            throw ParseError.invalidArgument(name: "resize", argument: raw)
        }
        return .resize(dimension, delta: CGFloat(isNegative ? -value : value))
    }

    private static func parseWorkspaceTarget(_ arguments: [String], name: String) throws
        -> WorkspaceTarget
    {
        guard arguments.count == 1 else {
            throw ParseError.wrongArgumentCount(name: name, expected: "1", got: arguments.count)
        }
        // i3 の `back_and_forth` も受ける。
        switch arguments[0] {
        case "back-and-forth", "back_and_forth": return .backAndForth
        case "next": return .next
        case "prev", "previous": return .previous
        default: return .index(try parseWorkspaceID(name, arguments))
        }
    }

    private static func parseMonitor(_ name: String, _ arguments: [String]) throws
        -> MonitorTarget
    {
        guard arguments.count == 1 else {
            throw ParseError.wrongArgumentCount(name: name, expected: "1", got: arguments.count)
        }
        // i3 は primary、AeroSpace は main。previous も受ける。
        switch arguments[0] {
        case "primary", "main": return .main
        case "previous", "prev": return .previous
        default:
            guard let target = MonitorTarget(rawValue: arguments[0]) else {
                throw ParseError.invalidArgument(name: name, argument: arguments[0])
            }
            return target
        }
    }

    private static func parseSplit(_ arguments: [String]) throws -> SplitTarget {
        guard arguments.count == 1 else {
            throw ParseError.wrongArgumentCount(name: "split", expected: "1", got: arguments.count)
        }
        // i3 の綴りは h / v / toggle。
        switch arguments[0] {
        case "h", "horizontal": return .horizontal
        case "v", "vertical": return .vertical
        case "toggle", "opposite": return .opposite
        default: throw ParseError.invalidArgument(name: "split", argument: arguments[0])
        }
    }

    private static func parseWorkspaceID(_ name: String, _ arguments: [String]) throws
        -> WorkspaceID
    {
        guard arguments.count == 1 else {
            throw ParseError.wrongArgumentCount(name: name, expected: "1", got: arguments.count)
        }
        // 番号は 1 以上。0 や負の番号は存在しないワークスペースを指す。
        guard let id = Int(arguments[0]), id >= 1 else {
            throw ParseError.invalidArgument(name: name, argument: arguments[0])
        }
        return id
    }

    private static func parseLayout(_ arguments: [String]) throws -> Command {
        guard !arguments.isEmpty else {
            throw ParseError.wrongArgumentCount(name: "layout", expected: "1 以上", got: 0)
        }
        // i3 の `layout toggle split` は「縦横を切り替える」意味。綴りをそのまま受ける。
        if arguments == ["toggle", "split"] {
            return .layout([.horizontal, .vertical])
        }
        // **accordion は綴りだけ受けて実装が無い。** 黙って受けると、押しても
        // 「向きが無い」と言われるだけで原因が分からない。ここで未対応と伝える。
        if arguments.contains("accordion") || arguments.contains("h_accordion")
            || arguments.contains("v_accordion")
        {
            throw ParseError.unsupported(name: "layout accordion")
        }
        let parsed = try arguments.map { argument -> LayoutArgument in
            guard let value = LayoutArgument(rawValue: argument) else {
                throw ParseError.invalidArgument(name: "layout", argument: argument)
            }
            return value
        }
        return .layout(parsed)
    }
}
