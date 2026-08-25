import CoreGraphics
import Testing

@testable import CometCore

@Suite("最小寸法の学習")
struct MinimumSizeLearningTests {

    @Test("要求位置で縮小だけを拒んだ結果は学習する")
    func learnsARealMinimumSize() {
        let target = CGRect(x: 962, y: 270, width: 476, height: 239)
        let observed = CGRect(x: 962, y: 270, width: 574, height: 239)

        let learned = MinimumSizeLearning.updatedSize(
            current: .zero, target: target, observed: observed)

        #expect(learned == CGSize(width: 574, height: 0))
    }

    /// Google Chrome で起きた回帰。`AXFullScreen` が true になる前に適用結果が返り、
    /// 画面全体の寸法を下限として覚えると、解除後も1枚だけ画面幅を占有していた。
    @Test("ネイティブ全画面の実測は最小寸法として学習しない")
    func nativeFullScreenIsNotAMinimumSize() {
        let target = CGRect(x: 964, y: 518, width: 468, height: 465)
        let observed = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let learned = MinimumSizeLearning.updatedSize(
            current: .zero, target: target, observed: observed)

        #expect(learned == nil)
    }

    @Test("過去に学習した下限は小さくしない")
    func learnedMinimumOnlyIncreases() {
        let target = CGRect(x: 10, y: 20, width: 400, height: 300)
        let observed = CGRect(x: 10, y: 20, width: 450, height: 350)

        let learned = MinimumSizeLearning.updatedSize(
            current: CGSize(width: 500, height: 320), target: target, observed: observed)

        #expect(learned == CGSize(width: 500, height: 350))
    }
}
