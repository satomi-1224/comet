import ApplicationServices
import CoreGraphics
import Darwin

/// SIP を無効化せずに使える非公開 API。
///
/// `_AXUIElementGetWindow` は `AXUIElement` から `CGWindowID` を取り出す。
/// 公開 API にこの機能はなく、ウィンドウを安定して一意識別するには実質これしかない
/// （`AXUIElement` は同一ウィンドウに対して複数インスタンスが生成されうるため、
/// 辞書キーには向かない）。
///
/// - Important: `@_silgen_name` による直接リンクは、OS アップデートでシンボルが
///   消えた場合に**起動時のリンクエラーでクラッシュする**。ここでは `dlsym` で
///   動的に解決し、欠落を実行時に検出できるようにしている。
public enum AXPrivate {

    public typealias GetWindowFunction = @convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let resolvedGetWindow: GetWindowFunction? = {
        // macOS の RTLD_DEFAULT。全ての読み込み済みイメージを対象にシンボルを探す。
        // 静的プロパティにすると UnsafeMutableRawPointer? が非 Sendable として
        // 並行性検査に引っかかるため、ここで局所的に作る。
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let symbol = dlsym(rtldDefault, "_AXUIElementGetWindow") {
            return unsafeBitCast(symbol, to: GetWindowFunction.self)
        }
        // ApplicationServices 経由で暗黙に読み込まれていない場合に備えて明示的に開く。
        // dyld 共有キャッシュ上のパスなのでファイルとしては存在しないが dlopen は解決できる。
        let path =
            "/System/Library/Frameworks/ApplicationServices.framework"
            + "/Frameworks/HIServices.framework/HIServices"
        if let handle = dlopen(path, RTLD_LAZY),
            let symbol = dlsym(handle, "_AXUIElementGetWindow")
        {
            return unsafeBitCast(symbol, to: GetWindowFunction.self)
        }
        return nil
    }()

    /// シンボルを解決できたか。OS アップデートによる欠落の検出に使う。
    public static var isGetWindowAvailable: Bool {
        resolvedGetWindow != nil
    }

    /// AX 要素に対応する `CGWindowID` を返す。
    ///
    /// ウィンドウ以外の要素、既に破棄された要素、応答しないプロセスの要素では `nil`。
    /// これらは異常系ではなく通常経路なので、呼び出し側は毎回 `nil` を想定すること。
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        try? identifier(of: element)
    }

    /// 失敗の理由が要るとき用。走査でウィンドウを取りこぼしたときの診断に使う。
    ///
    /// 「ID を取れなかった」だけでは、疑似ウィンドウ（Finder のデスクトップなど）なのか、
    /// 権限が外れているのか、応答しないアプリなのかが切り分けられない。
    public static func identifier(of element: AXUIElement) throws -> CGWindowID {
        guard let getWindow = resolvedGetWindow else { throw Failure.symbolMissing }
        var identifier: CGWindowID = 0
        let error = getWindow(element, &identifier)
        guard error == .success else { throw Failure.axError(error) }
        guard identifier != 0 else { throw Failure.zeroIdentifier }
        return identifier
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case symbolMissing
        case axError(AXError)
        /// 呼び出しは成功したが 0 が返った。ウィンドウとして扱えない。
        case zeroIdentifier

        public var description: String {
            switch self {
            case .symbolMissing:
                "_AXUIElementGetWindow を解決できていない"
            case .zeroIdentifier:
                "ID が 0（ウィンドウとして扱えない要素）"
            case .axError(let error):
                switch error {
                case .apiDisabled: "アクセシビリティ権限が無効"
                case .illegalArgument:
                    "引数が不正（疑似ウィンドウか、権限が外れている。全滅なら後者）"
                case .invalidUIElement: "要素が無効（疑似ウィンドウか、すでに破棄されている）"
                case .cannotComplete: "応答が得られない（アプリがビジーかタイムアウト）"
                case .notImplemented: "アプリがこの問い合わせに対応していない"
                default: "AXError(\(error.rawValue))"
                }
            }
        }
    }
}
