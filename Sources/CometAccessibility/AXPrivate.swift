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
///   動的に解決し、欠落を実行時に検出できるようにしている（設計書 §12.2）。
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
        guard let getWindow = resolvedGetWindow else { return nil }
        var identifier: CGWindowID = 0
        let error = getWindow(element, &identifier)
        guard error == .success, identifier != 0 else { return nil }
        return identifier
    }
}
