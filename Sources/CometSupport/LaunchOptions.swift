import Foundation

public enum LaunchOptionsError: Error, Equatable, CustomStringConvertible {
    case unknownFlag(String)
    case unexpectedArgument(String)
    case missingValue(flag: String)
    case invalidLogLevel(String)
    case invalidWindowCount(String)

    public var description: String {
        switch self {
        case .unknownFlag(let flag):
            "未知のオプション: \(flag)"
        case .unexpectedArgument(let arg):
            "予期しない引数: \(arg)"
        case .missingValue(let flag):
            "\(flag) に値が指定されていない"
        case .invalidWindowCount(let value):
            "ウィンドウ枚数は 1 以上の整数を指定する: \(value)"
        case .invalidLogLevel(let value):
            "不正なログレベル: \(value)（有効な値: "
                + LogLevel.allCases.map(\.name).joined(separator: ", ") + "）"
        }
    }
}

/// コマンドライン引数。
///
/// 解釈を純粋関数に切り出してあるのはテストのためで、
/// 実行時の副作用（ログ設定・ホットキー登録）は呼び出し側が行う。
public struct LaunchOptions: Equatable, Sendable {

    /// `--log-level` の明示的な指定。無ければ `nil`。
    ///
    /// 既定値を持たせないのは、設定ファイルの `[debug] log-level` と
    /// 優先順位を付けられるようにするため（コマンドライン > 設定 > 既定）。
    public var logLevel: LogLevel?
    /// 優先順位を解決したあとのログレベル。
    public func resolvedLogLevel(configured: LogLevel?) -> LogLevel {
        logLevel ?? configured ?? .info
    }
    public var hotkeys: [String] = []
    public var showHelp: Bool = false
    public var printKeys: Bool = false
    /// レイアウトを計算するがウィンドウは動かさない。
    /// 他のウィンドウマネージャが動いている環境で検証するために使う。
    public var dryRun: Bool = false
    /// 指定枚数のレイアウトを図示して終了する。ウィンドウには一切触れない。
    public var previewLayout: Int?
    /// 設定ファイルの場所。無指定なら既定の場所を使う。
    public var configPath: String?
    /// 設定ファイルを読まずに組み込みの既定で起動する。
    public var ignoreConfig: Bool = false
    /// 組み込みの既定設定を出力して終了する。設定ファイルの雛形になる。
    public var printDefaultConfig: Bool = false
    /// 検証用: 合成キーを送って終了する。`spec:count` の形（count は省略可）。
    ///
    /// イベントの送出には送る側にアクセシビリティ権限が要る。権限を持つのは
    /// comet 自身なので、この口を製品バイナリに置いている。
    public var emitKey: String?
    /// 検証用: 合成ドラッグを送って終了する。`x,y:dx,dy` の形。
    public var emitDrag: String?
    /// 検証用: ポインタを動かして終了する。`x,y` の形。
    public var emitMove: String?

    /// 常駐している comet へ送るコマンド（i3 の `i3-msg`）。送ったら終了する。
    public var send: String?
    /// 常駐している comet に問い合わせる話題。答えを出したら終了する。
    public var query: String?
    /// 起動後に実行するコマンド。複数回指定でき、書いた順に実行される。
    ///
    /// ホットキーを押せない環境（合成キーの送出に別の権限が要る）でも
    /// コマンドの経路を通せるようにするための検証用の口。
    public var commands: [String] = []

    public init() {}

    public static let usage: String = """
        comet — macOS タイリングウィンドウマネージャ

        使い方:
          comet [オプション]

        オプション:
          --log-level <level>   ログレベル (\(LogLevel.allCases.map(\.name).joined(separator: "|")))
                                既定: 設定ファイルの値、無ければ info
          --config <path>       設定ファイルの場所
                                既定: ~/.config/comet/config.toml
          --no-config           設定ファイルを読まず組み込みの既定で起動する
          --print-default-config
                                組み込みの既定設定を出力して終了する。
                                設定ファイルの雛形になる。
          --hotkey <spec>       押下をログに出すだけの確認用ホットキー。複数回指定できる。
                                例: --hotkey alt-h --hotkey cmd-shift-space
          --dry-run             レイアウトを計算するがウィンドウは動かさない。
                                他のウィンドウマネージャが動いている環境での検証用。
          --preview-layout <n>  n 枚のときのレイアウトを図示して終了する。
                                ウィンドウには一切触れない。
          --run <command>       起動後にコマンドを実行する。複数回指定でき順に実行する。
                                例: --run "workspace 2" --run "move left"
                                ホットキーを押せない環境での検証用。

        常駐している comet を外から動かす（i3 の i3-msg 相当。送ったら終了する）:
          --send <command>      コマンドを送る。設定に書ける綴りがそのまま使える。
                                例: comet --send "workspace 3"
                                    comet --send "move-node-to-monitor next"
          --query <topic>       状態を問い合わせる。状態バーから読める形で返る。
                                workspaces  ワークスペースの一覧（1行1件）
                                windows     ウィンドウの一覧（1行1件）
                                monitors    ディスプレイの一覧（1行1件）
                                tree        分割の形
                                state       まとめ（1行）
                                例: comet --query workspaces

        検証用（送って終了する。常駐しない）:
          --emit-key <spec[:n]> 合成キーを送る。n を 2 以上にするとキー連射を再現する。
                                例: --emit-key alt-ctrl-l:20
          --emit-drag <x,y:dx,dy>
                                合成ドラッグを送る。座標は左上原点。
                                例: --emit-drag 1278,860:-200,0
          --emit-move <x,y>     ポインタを動かす（ボタンは押さない）。
                                focus-follows-mouse の確認に使う。
          --print-keys          指定できるキー名を一覧表示して終了する
          --help, -h            このヘルプを表示して終了する

        常駐中のホットキー:
          ctrl-alt-shift-q      終了
          ctrl-alt-shift-r      再配置

        ホットキーの書式:
          修飾キーとキーをハイフンで連ねる。修飾キーは cmd / alt / ctrl / shift
          （別名: command, opt, option, control）。最後の要素がキー。
          "-" 自体を指定するときは minus と綴る。
        """

    public static func parse(_ args: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0

        while index < args.count {
            let arg = args[index]

            // --flag=value 形式を先に分解する
            if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
                let flag = String(arg[arg.startIndex..<equals])
                let value = String(arg[arg.index(after: equals)...])
                // "--log-level=" のように値が空の場合は、不正な値ではなく欠落として扱う。
                // 「不正なログレベル: 」という中身のない診断を出さないため。
                guard !value.isEmpty else {
                    throw LaunchOptionsError.missingValue(flag: flag)
                }
                switch flag {
                case "--log-level":
                    guard let level = LogLevel(name: value) else {
                        throw LaunchOptionsError.invalidLogLevel(value)
                    }
                    options.logLevel = level
                case "--hotkey":
                    options.hotkeys.append(value)
                case "--preview-layout":
                    guard let count = Int(value), count > 0 else {
                        throw LaunchOptionsError.invalidWindowCount(value)
                    }
                    options.previewLayout = count
                case "--config":
                    options.configPath = value
                case "--run":
                    options.commands.append(value)
                case "--emit-key":
                    options.emitKey = value
                case "--emit-drag":
                    options.emitDrag = value
                case "--emit-move":
                    options.emitMove = value
                case "--send":
                    options.send = value
                case "--query":
                    options.query = value
                default:
                    throw LaunchOptionsError.unknownFlag(flag)
                }
                index += 1
                continue
            }

            switch arg {
            case "--help", "-h":
                options.showHelp = true
                index += 1

            case "--print-keys":
                options.printKeys = true
                index += 1

            case "--print-default-config":
                options.printDefaultConfig = true
                index += 1

            case "--no-config":
                options.ignoreConfig = true
                index += 1

            case "--dry-run":
                options.dryRun = true
                index += 1

            case "--log-level":
                let value = try takeValue(args, after: &index, flag: arg)
                guard let level = LogLevel(name: value) else {
                    throw LaunchOptionsError.invalidLogLevel(value)
                }
                options.logLevel = level

            case "--hotkey":
                options.hotkeys.append(try takeValue(args, after: &index, flag: arg))

            case "--config":
                options.configPath = try takeValue(args, after: &index, flag: arg)

            case "--run":
                options.commands.append(try takeValue(args, after: &index, flag: arg))

            case "--emit-key":
                options.emitKey = try takeValue(args, after: &index, flag: arg)

            case "--emit-drag":
                options.emitDrag = try takeValue(args, after: &index, flag: arg)

            case "--emit-move":
                options.emitMove = try takeValue(args, after: &index, flag: arg)

            case "--send":
                options.send = try takeValue(args, after: &index, flag: arg)

            case "--query":
                options.query = try takeValue(args, after: &index, flag: arg)

            case "--preview-layout":
                let value = try takeValue(args, after: &index, flag: arg)
                guard let count = Int(value), count > 0 else {
                    throw LaunchOptionsError.invalidWindowCount(value)
                }
                options.previewLayout = count

            default:
                if arg.hasPrefix("-") {
                    throw LaunchOptionsError.unknownFlag(arg)
                }
                throw LaunchOptionsError.unexpectedArgument(arg)
            }
        }

        return options
    }

    /// `index` が指すフラグの次の要素を値として取り出し、`index` をその先へ進める。
    ///
    /// 値の位置に別のフラグが来た場合は「値の欠落」として扱う。
    /// 黙って飲み込むと `--log-level --hotkey alt-h` のような打ち間違いが
    /// 診断されないまま通ってしまうため。
    private static func takeValue(
        _ args: [String], after index: inout Int, flag: String
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < args.count else {
            throw LaunchOptionsError.missingValue(flag: flag)
        }
        let value = args[valueIndex]
        guard !value.hasPrefix("-") else {
            throw LaunchOptionsError.missingValue(flag: flag)
        }
        index = valueIndex + 1
        return value
    }
}
