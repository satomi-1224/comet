import CoreGraphics

/// ウィンドウの重なりの階層（`kCGWindowLayer`）を読む。
///
/// **AX からは分からない情報。** ピクチャーインピクチャの窓は AX 上ふつうの
/// ウィンドウに見える（実測: `role=AXWindow` `subrole=AXStandardWindow`
/// `title="ピクチャー イン ピクチャー"` 571x321）。role でも subrole でも大きさでも
/// 見分けられないので、そのままでは並べる対象に入ってしまう。
///
/// 一方 `kCGWindowLayer` は **通常のウィンドウが 0、常に手前へ出る窓は 3** と
/// はっきり分かれる。並べる対象かどうかはこちらで見る。
public enum WindowLayers {

    /// 通常のウィンドウの階層。
    public static let normal = 0

    /// ウィンドウ ID から階層への対応。
    ///
    /// **画面に出ているものだけを見る。** 画面外を含める `optionAll` は実測で
    /// 4.4ms（110枚）かかり、新規ウィンドウが着地するまでの予算（実測 14〜36ms）を
    /// 大きく削る。画面上だけなら 0.3ms で済む。取りこぼしたウィンドウは
    /// 「分からない」となり従来どおり管理されるので、害は無い。
    ///
    /// - Returns: 取得に失敗したときは `nil`。**空の辞書と区別する。**
    ///   「分からない」を「階層 0 ではない」と扱うと、普通のウィンドウが
    ///   まとめて管理対象から外れる。
    public static func snapshot() -> [CGWindowID: Int]? {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        var layers: [CGWindowID: Int] = [:]
        layers.reserveCapacity(list.count)
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                let layer = info[kCGWindowLayer as String] as? Int
            else { continue }
            layers[id] = layer
        }
        return layers
    }

    public static func layer(of id: CGWindowID) -> Int? {
        snapshot()?[id]
    }
}
