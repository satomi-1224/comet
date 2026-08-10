/// 正規化の設定。既定は現行 AeroSpace 設定に合わせて両方とも有効。
public struct NormalizationConfig: Sendable, Equatable {

    /// 子が1つだけのコンテナを潰し、その子を親へ昇格させる。
    public var flattenContainers: Bool

    /// コンテナの子コンテナを、親と逆の向きにする。
    public var oppositeOrientationForNested: Bool

    public init(flattenContainers: Bool = true, oppositeOrientationForNested: Bool = true) {
        self.flattenContainers = flattenContainers
        self.oppositeOrientationForNested = oppositeOrientationForNested
    }

    public static let `default` = NormalizationConfig()
    public static let off = NormalizationConfig(
        flattenContainers: false, oppositeOrientationForNested: false)
}

/// 木の形を整える。**木を変更するすべてのコマンドの直後、レイアウト計算の直前に走る。**
///
/// 空コンテナの除去と比率の修復は不変条件なので設定に関わらず常に行う。
/// 潰しと向きの反転だけが設定で切れる。
public enum Normalization {

    public static func normalize(_ root: ContainerNode, config: NormalizationConfig = .default) {
        // 三段に分ける理由:
        //
        // 1. 潰しは**葉から**でなければならない。子を潰した結果で親の判定が変わる。
        // 2. 向きの反転は**根から**でなければならない。親を直した結果で子の判定が変わる。
        // 3. 反転は子の数を変えないので、2 が新たな潰しの機会を作ることはない。
        //    したがってこの順で一度ずつ回せば収束する。
        collapse(root, config: config, isRoot: true)
        if config.oppositeOrientationForNested {
            fixOrientations(root)
        }
        repairWeights(root)
    }

    /// 空コンテナの除去と単一子コンテナの潰し。葉から根へ。
    ///
    /// - Important: **同じ添字へ戻る `continue` は、必ず成功した変更に紐づけること。**
    ///   木が壊れていて変更が空振りしたときに同じ添字を見直し続けると、
    ///   常駐プロセスがそこで固まる。以下では `continue` の条件に
    ///   「ノード数が確かに減った」ことを含めてあるので、必ず停止する。
    private static func collapse(
        _ container: ContainerNode, config: NormalizationConfig, isRoot: Bool
    ) {
        var index = 0
        while index < container.children.count {
            guard let child = container.children[index] as? ContainerNode else {
                index += 1
                continue
            }

            collapse(child, config: config, isRoot: false)

            // 空のコンテナは領域を食うだけで何も表示しない。設定に関わらず除く。
            // 後ろが詰まってくるので同じ添字を見直す。
            if child.isEmpty, container.remove(at: index) != nil {
                continue
            }

            // 取り分と位置は差し替えで引き継がれる。昇格した子がまたコンテナなら
            // 同じ添字を見直して連鎖的に潰す。
            if config.flattenContainers, child.children.count == 1,
                container.replace(at: index, with: child.children[0]) != nil
            {
                continue
            }

            index += 1
        }

        // ルートは消せないので、唯一の子がコンテナなら取り込む形で潰す。
        // 取り込んだ結果また唯一の子になることがある（H[V[H[1,2]]] など）。
        while isRoot, config.flattenContainers, container.children.count == 1,
            let only = container.children[0] as? ContainerNode
        {
            guard container.absorb(only) else { break }
        }
    }

    /// 入れ子コンテナを親と逆向きにする。根から葉へ。
    ///
    /// 利用者が `layout` コマンドで選んだ向きは対象外。自動で組まれた形を整えるための
    /// 規則なので、手で選んだものに適用すると設定したそばから戻ってしまう。
    private static func fixOrientations(_ container: ContainerNode) {
        for child in container.children {
            guard let nested = child as? ContainerNode else { continue }
            if !nested.isOrientationExplicit, nested.orientation == container.orientation {
                nested.orientation = container.orientation.flipped
            }
            fixOrientations(nested)
        }
    }

    private static func repairWeights(_ container: ContainerNode) {
        container.repairWeights()
        for child in container.children {
            guard let nested = child as? ContainerNode else { continue }
            repairWeights(nested)
        }
    }
}
