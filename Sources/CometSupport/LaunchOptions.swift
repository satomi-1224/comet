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

    public var logLevel: LogLevel = .info
    public var hotkeys: [String] = []
    public var showHelp: Bool = false
    public var printKeys: Bool = false
    /// レイアウトを計算するがウィンドウは動かさない。
    /// 他のウィンドウマネージャが動いている環境で検証するために使う。
    public var dryRun: Bool = false
    /// 指定枚数のレイアウトを図示して終了する。ウィンドウには一切触れない。
    public var previewLayout: Int?

    public init() {}

    public static let usage: String = """
        comet — macOS タイリングウィンドウマネージャ

        使い方:
          comet [オプション]

        オプション:
          --log-level <level>   ログレベル (\(LogLevel.allCases.map(\.name).joined(separator: "|")))
                                既定: info
          --hotkey <spec>       押下をログに出すだけの確認用ホットキー。複数回指定できる。
                                例: --hotkey alt-h --hotkey cmd-shift-space
          --dry-run             レイアウトを計算するがウィンドウは動かさない。
                                他のウィンドウマネージャが動いている環境での検証用。
          --preview-layout <n>  n 枚のときのレイアウトを図示して終了する。
                                ウィンドウには一切触れない。
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
