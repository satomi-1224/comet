import CoreGraphics
import Testing

@testable import CometCore

/// 内蔵UI のうち、AppKit に触らない部分。
///
/// 色の解釈と枠線の幾何はここで固める。描画そのものは実機でしか確かめられない。
@Suite("DecorationStyle")
struct DecorationStyleTests {

    // MARK: - 色

    @Test("#RRGGBB を解釈する")
    func parsesSixDigitHex() throws {
        let color = try #require(RGBAColor(hex: "#7aa2f7"))
        #expect(abs(color.red - 122.0 / 255) < 1e-9)
        #expect(abs(color.green - 162.0 / 255) < 1e-9)
        #expect(abs(color.blue - 247.0 / 255) < 1e-9)
        #expect(color.alpha == 1)
    }

    @Test("# は省略できる")
    func hashIsOptional() {
        #expect(RGBAColor(hex: "7aa2f7") == RGBAColor(hex: "#7aa2f7"))
    }

    @Test("大文字小文字を問わない")
    func caseInsensitive() {
        #expect(RGBAColor(hex: "#7AA2F7") == RGBAColor(hex: "#7aa2f7"))
    }

    @Test("#RGB は各桁を2回繰り返した形と同じ")
    func parsesThreeDigitHex() {
        #expect(RGBAColor(hex: "#f0a") == RGBAColor(hex: "#ff00aa"))
    }

    @Test("#RRGGBBAA は透明度も読む")
    func parsesEightDigitHex() throws {
        let color = try #require(RGBAColor(hex: "#00000080"))
        #expect(abs(color.alpha - 128.0 / 255) < 1e-9)
    }

    @Test("極端な値も潰れない")
    func parsesExtremes() {
        #expect(RGBAColor(hex: "#000000") == RGBAColor(red: 0, green: 0, blue: 0))
        #expect(RGBAColor(hex: "#ffffff") == RGBAColor(red: 1, green: 1, blue: 1))
    }

    // 打ち間違いを黙って黒にすると原因が分からない。失敗として返す。
    @Test("解釈できない色は nil")
    func rejectsInvalidHex() {
        for text in ["", "#", "#12", "#12345", "#1234567", "#gggggg", "blue", "#7aa2f7 x"] {
            #expect(RGBAColor(hex: text) == nil, "\"\(text)\"")
        }
    }

    @Test("成分は 0〜1 に収まる")
    func componentsAreClamped() {
        let color = RGBAColor(red: 5, green: -1, blue: 0.5, alpha: 9)
        #expect(color.red == 1)
        #expect(color.green == 0)
        #expect(color.blue == 0.5)
        #expect(color.alpha == 1)
    }

    // MARK: - 枠線の幾何

    // ウィンドウと同一の矩形にすると枠が中身に被る。線の幅だけ外へ広げる。
    @Test("枠線は線の幅だけ外側へ広がる")
    func borderFrameExpandsOutward() {
        let style = BorderStyle(width: 2)
        let frame = style.frame(around: CGRect(x: 100, y: 200, width: 300, height: 400))

        #expect(frame == CGRect(x: 98, y: 198, width: 304, height: 404))
    }

    @Test("線の幅 0 なら矩形は変わらない")
    func zeroWidthKeepsRect() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(BorderStyle(width: 0).frame(around: rect) == rect)
    }

    @Test("負の線幅と半径は 0 に丸める")
    func negativeValuesAreClamped() {
        let style = BorderStyle(width: -5, radius: -3)
        #expect(style.width == 0)
        #expect(style.radius == 0)
    }

    @Test("既定は枠線を出す")
    func borderIsEnabledByDefault() {
        #expect(BorderStyle().isEnabled)
        #expect(BorderStyle().width == 2)
    }

    // MARK: - インジケータの出し方

    @Test("出し方の組み合わせ")
    func indicatorStyleCombinations() {
        #expect(IndicatorStyle.menubar.showsMenubar)
        #expect(!IndicatorStyle.menubar.showsHUD)
        #expect(!IndicatorStyle.hud.showsMenubar)
        #expect(IndicatorStyle.hud.showsHUD)
        #expect(IndicatorStyle.both.showsMenubar && IndicatorStyle.both.showsHUD)
        #expect(!IndicatorStyle.off.showsMenubar && !IndicatorStyle.off.showsHUD)
    }
}
