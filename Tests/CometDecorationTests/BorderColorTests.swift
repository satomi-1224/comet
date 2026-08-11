import CoreGraphics
import Testing

import CometCore
import CometDecoration

/// 設定に書いた色が、画面にその色として出るか。
///
/// 撮った画面の画素と設定の綴りを突き合わせる検証を入れたときに、
/// **`#ff00ff` と書いた枠線が `#ff40ff` として写っていた**ことで見つかった問題。
///
/// 原因は `CGColor(red:green:blue:alpha:)` が色空間を **Generic RGB** にすること。
/// Generic RGB の (1, 0, 1) は sRGB では (255, 64, 255) に相当するので、
/// 設定に書いた値とは違う色が描かれていた。
@Suite("枠線の色")
struct BorderColorTests {

    @Test("設定の綴りがそのまま sRGB の値になる")
    func colorSpaceIsSRGB() {
        let color = RGBAColor(hex: "#ff00ff")!
        let cgColor = color.cgColor
        #expect(cgColor.colorSpace?.name == CGColorSpace.sRGB)
        #expect(cgColor.components == [1, 0, 1, 1])
    }

    @Test("既定の枠線色も綴りどおりの値になる")
    func defaultBorderColor() {
        let cgColor = BorderStyle().focusedColor.cgColor
        #expect(cgColor.colorSpace?.name == CGColorSpace.sRGB)
        // #7aa2f7
        let components = cgColor.components ?? []
        #expect(components.count == 4)
        #expect(Int((components[0] * 255).rounded()) == 0x7a)
        #expect(Int((components[1] * 255).rounded()) == 0xa2)
        #expect(Int((components[2] * 255).rounded()) == 0xf7)
    }

    @Test("透過も保たれる")
    func alphaIsPreserved() {
        let color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        #expect(color.cgColor.alpha == 0.5)
    }
}
