import CoreGraphics

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

/// `workspace` コマンドの行き先。
public enum WorkspaceTarget: Equatable, Sendable {
    case index(WorkspaceID)
    /// 直前のワークスペースへ戻る。続けて押すと2つの間を往復する。
    case backAndForth
}

/// ホットキーから実行される操作。**文字列表現は AeroSpace 互換**にしてある。
///
/// 互換にしておくと、現行の AeroSpace 設定をほぼそのまま持ってこられる。
public enum Command: Equatable, Sendable, CustomStringConvertible {

    case focus(Direction)
    case move(Direction)
    case resize(Dimension, delta: CGFloat)
    case joinWith(Direction)
    /// 引数を順に巡回して次の状態にする（`layout tiles horizontal vertical` など）。
    case layout([LayoutArgument])
    case workspace(WorkspaceTarget)
    /// フォーカス中のウィンドウを別のワークスペースへ移す。表示は切り替えない。
    case moveNodeToWorkspace(WorkspaceID)

    /// 設定に書ける綴りへ戻す。ログで「どのコマンドが動いたか」を追えるようにする。
    public var description: String {
        switch self {
        case .focus(let direction): "focus \(direction.rawValue)"
        case .move(let direction): "move \(direction.rawValue)"
        case .joinWith(let direction): "join-with \(direction.rawValue)"
        case .resize(let dimension, let delta):
            "resize \(dimension.rawValue) \(delta < 0 ? "" : "+")\(Int(delta))"
        case .layout(let arguments):
            "layout \(arguments.map(\.rawValue).joined(separator: " "))"
        case .workspace(.index(let id)):
            "workspace \(id)"
        case .workspace(.backAndForth):
            "workspace back-and-forth"
        case .moveNodeToWorkspace(let id):
            "move-node-to-workspace \(id)"
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

    /// 後続の Phase で実装するコマンド。
    ///
    /// 「不明」と分けておかないと、設定の綴り間違いなのか未実装なのかが区別できない。
    private static let plannedCommands: Set<String> = [
        "move-workspace-to-monitor", "move-node-to-monitor", "fullscreen", "mode",
        "close-window", "reload-config", "focus-monitor", "flatten-workspace-tree",
    ]

    public static func parse(_ text: String) throws -> Command {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = tokens.first else { throw ParseError.empty }
        let arguments = Array(tokens.dropFirst())

        switch name {
        case "focus":
            return .focus(try parseDirection(name, arguments))
        case "move":
            return .move(try parseDirection(name, arguments))
        case "join-with":
            return .joinWith(try parseDirection(name, arguments))
        case "resize":
            return try parseResize(arguments)
        case "layout":
            return try parseLayout(arguments)
        case "workspace":
            return .workspace(try parseWorkspaceTarget(arguments))
        case "move-node-to-workspace":
            return .moveNodeToWorkspace(try parseWorkspaceID(name, arguments))
        default:
            throw plannedCommands.contains(name)
                ? ParseError.unsupported(name: name)
                : ParseError.unknown(name: name)
        }
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

    private static func parseResize(_ arguments: [String]) throws -> Command {
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

    private static func parseWorkspaceTarget(_ arguments: [String]) throws -> WorkspaceTarget {
        guard arguments.count == 1 else {
            throw ParseError.wrongArgumentCount(
                name: "workspace", expected: "1", got: arguments.count)
        }
        if arguments[0] == "back-and-forth" {
            return .backAndForth
        }
        return .index(try parseWorkspaceID("workspace", arguments))
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
        let parsed = try arguments.map { argument -> LayoutArgument in
            guard let value = LayoutArgument(rawValue: argument) else {
                throw ParseError.invalidArgument(name: "layout", argument: argument)
            }
            return value
        }
        return .layout(parsed)
    }
}
