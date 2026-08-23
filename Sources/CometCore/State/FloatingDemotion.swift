import CoreGraphics

/// 目標に追従しないウィンドウをフローティングへ降格させるかの判定。**純粋関数。**
///
/// ## 何を捕まえたいのか
///
/// AX での位置・寸法の設定を**まるごと無視するアプリ**がある。タイル配置として
/// 成立しないので、並べる対象から外して重なりを止めるしかない。
///
/// ## 取り違えてはいけないもの
///
/// | 実測 | 意味 | 正しい扱い |
/// |---|---|---|
/// | 要求 476x239 → 実際 574x239（Safari） | 最小寸法がある | 下限として学習する |
/// | 要求 955x964 → 実際 955x959（ターミナル） | 文字セル単位への丸め | そのまま受け入れる |
/// | 要求 (5,61) → 実際 (1707,61) | 位置を無視している | **降格** |
///
/// **「目標より大きい」を理由にしてはいけない。** それは下限があるという意味で、
/// 値は `Engine.learnMinimum` が覚えている。次の再配置ではその下限を織り込んだ
/// 目標になるので、放っておけば収まる。実測では、Safari の最小幅 574 を学習した
/// **76ms 後に同じ理由で降格**しており、学習が打ち消されてウィンドウが勝手に浮いた。
public enum FloatingDemotion {

    /// 降格させるべきか。
    ///
    /// - Parameters:
    ///   - target: 要求した矩形。
    ///   - observed: 補正を諦めた時点の実際の矩形。
    ///   - threshold: これ以下のずれは降格の理由にしない。丸めや下限は
    ///     数十 pt で収まるので、常用ウィンドウが浮かないための歯止め。
    public static func shouldDemote(
        target: CGRect, observed: CGRect, threshold: CGFloat
    ) -> Bool {
        max(positionError(target: target, observed: observed),
            growthShortfall(target: target, observed: observed)) > threshold
    }

    /// 位置のずれ。**タイル配置として成立するかを決める。**
    public static func positionError(target: CGRect, observed: CGRect) -> CGFloat {
        max(abs(observed.minX - target.minX), abs(observed.minY - target.minY))
    }

    /// 要求より小さいまま広がらない量。**下限では説明できないずれ。**
    ///
    /// 負の値（要求より大きい）は下限があるということなので、ここでは 0 として扱う。
    public static func growthShortfall(target: CGRect, observed: CGRect) -> CGFloat {
        max(0, max(target.width - observed.width, target.height - observed.height))
    }
}
