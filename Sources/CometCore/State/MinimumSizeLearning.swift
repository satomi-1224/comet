import CoreGraphics

/// アプリが拒んだ縮小量を、次のレイアウトで使う最小寸法へ変換する純粋な判定。
public enum MinimumSizeLearning {

    /// 実測から更新した最小寸法を返す。新しく学ぶものが無ければ `nil`。
    ///
    /// 本物の最小寸法に当たったウィンドウは、要求した左上を保ったまま寸法だけが
    /// 大きくなる。一方、ネイティブ全画面や AX の書き込みを無視するウィンドウは
    /// 位置も要求から外れる。その実測を下限として覚えると、全画面をやめたあとも
    /// 画面幅を要求し続けるため、位置が一致した場合にだけ学習する。
    public static func updatedSize(
        current: CGSize,
        target: CGRect,
        observed: CGRect,
        positionTolerance: CGFloat = 1,
        sizeSlack: CGFloat = 1
    ) -> CGSize? {
        guard
            FloatingDemotion.positionError(target: target, observed: observed)
                <= positionTolerance
        else {
            return nil
        }

        var learned = current
        var changed = false
        if observed.width > target.width + sizeSlack, observed.width > learned.width {
            learned.width = observed.width
            changed = true
        }
        if observed.height > target.height + sizeSlack, observed.height > learned.height {
            learned.height = observed.height
            changed = true
        }
        return changed ? learned : nil
    }
}
