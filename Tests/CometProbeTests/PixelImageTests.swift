import Testing

@testable import CometProbe

/// 撮った画面から「枠線が出ているか」「HUD が出て消えたか」を判定するための計算。
///
/// 判定を目で見るのをやめて機械にやらせるには、次の2つだけあれば足りる。
///
/// - **特定の色が描かれている範囲**（枠線は他に出てこない色で描かせる）
/// - **2枚の画像で変わった画素の数**（HUD やメニューバーの表示は差分で捉える）
///
/// どちらも画素の並びに対する純粋な計算なので、実際に撮影せずに固められる。
@Suite("PixelImage")
struct PixelImageTests {

    private let magenta = PixelColor(red: 255, green: 0, blue: 255)
    private let black = PixelColor(red: 0, green: 0, blue: 0)

    // MARK: - 色の範囲

    @Test("一致する画素が無ければ範囲は無い")
    func noMatch() {
        let canvas = Canvas(width: 10, height: 10, fill: black)
        #expect(canvas.image.boundingBox(matching: magenta, tolerance: 0) == nil)
    }

    @Test("1画素だけ一致すれば 1x1 の範囲になる")
    func singlePixel() {
        var canvas = Canvas(width: 10, height: 10, fill: black)
        canvas.set(x: 3, y: 7, to: magenta)
        let match = canvas.image.boundingBox(matching: magenta, tolerance: 0)
        #expect(match?.rect == IntRect(x: 3, y: 7, width: 1, height: 1))
        #expect(match?.count == 1)
    }

    /// 枠線は**中身が空の矩形**として描かれる。塗り潰しを前提にすると判定できない。
    @Test("中身が空の矩形でも外周の範囲を返す")
    func hollowRectangle() {
        var canvas = Canvas(width: 40, height: 30, fill: black)
        canvas.stroke(IntRect(x: 5, y: 4, width: 20, height: 10), color: magenta, lineWidth: 2)
        let match = canvas.image.boundingBox(matching: magenta, tolerance: 0)
        #expect(match?.rect == IntRect(x: 5, y: 4, width: 20, height: 10))
        // 塗り潰し (200) ではなく縁だけ: 20*10 - 16*6 = 104
        #expect(match?.count == 104)
    }

    /// 縁は必ず前後の色と混ざる（角丸と反エイリアス）。厳密一致では枠線を見つけられない。
    @Test("許容差の内側なら混ざった色も同じ色とみなす")
    func tolerance() {
        var canvas = Canvas(width: 10, height: 10, fill: black)
        canvas.set(x: 2, y: 2, to: PixelColor(red: 250, green: 6, blue: 249))
        #expect(canvas.image.boundingBox(matching: magenta, tolerance: 3) == nil)
        #expect(canvas.image.boundingBox(matching: magenta, tolerance: 8) != nil)
    }

    /// 枠線ウィンドウ自体は透過だが、**撮影した画像では合成後の不透明な色**になる。
    /// アルファを比較に入れると、透過で描いた色が一致しなくなる。
    @Test("アルファは比較に入れない")
    func alphaIsIgnored() {
        var canvas = Canvas(width: 10, height: 10, fill: black)
        canvas.set(x: 1, y: 1, to: magenta, alpha: 0)
        #expect(canvas.image.boundingBox(matching: magenta, tolerance: 0)?.count == 1)
    }

    /// 画面の端に接した枠線を1画素落とすと、位置がずれたのか幅が違うのか分からなくなる。
    @Test("画像の端に接していても範囲が切れない")
    func touchingEdges() {
        var canvas = Canvas(width: 8, height: 6, fill: black)
        canvas.stroke(IntRect(x: 0, y: 0, width: 8, height: 6), color: magenta, lineWidth: 1)
        let match = canvas.image.boundingBox(matching: magenta, tolerance: 0)
        #expect(match?.rect == IntRect(x: 0, y: 0, width: 8, height: 6))
    }

    @Test("範囲を限れば外側に描かれた色は拾わない")
    func boundingBoxWithinRegion() {
        var canvas = Canvas(width: 20, height: 20, fill: black)
        canvas.set(x: 1, y: 1, to: magenta)
        canvas.set(x: 15, y: 15, to: magenta)
        let match = canvas.image.boundingBox(
            matching: magenta, tolerance: 0, in: IntRect(x: 10, y: 10, width: 10, height: 10))
        #expect(match?.rect == IntRect(x: 15, y: 15, width: 1, height: 1))
        #expect(match?.count == 1)
    }

    // MARK: - 四辺の一致

    /// 枠線の判定に**範囲（bbox）を使ってはいけない。** 範囲は一致した画素全部を
    /// 囲むので、画面のどこか（写真や動画の1画素）に同じ色が写っていると、
    /// そこまで含んだ巨大な矩形になって判定が崩れる。
    ///
    /// 「目標の矩形の四辺に、その色がどれだけ乗っているか」で見れば、
    /// 無関係な写り込みには影響されない。
    @Test("四辺すべてに色が乗っていれば一致は 1.0")
    func fullyDrawnEdges() {
        var canvas = Canvas(width: 60, height: 40, fill: black)
        let rect = IntRect(x: 10, y: 8, width: 30, height: 20)
        canvas.stroke(rect, color: magenta, lineWidth: 2)
        let coverage = canvas.image.edgeCoverage(of: rect, color: magenta, tolerance: 0)
        #expect(coverage?.minimum == 1.0)
    }

    @Test("何も描かれていなければ一致は 0")
    func nothingDrawn() {
        let canvas = Canvas(width: 60, height: 40, fill: black)
        let coverage = canvas.image.edgeCoverage(
            of: IntRect(x: 10, y: 8, width: 30, height: 20), color: magenta, tolerance: 0)
        #expect(coverage?.minimum == 0)
    }

    /// 枠線には角丸が付く（既定 10pt）。角の円弧は辺の直線上に無いので、
    /// 端まで数えると必ず欠ける。**両端を切って中央だけを見る。**
    @Test("角が欠けていても端を切れば一致する")
    func roundedCorners() {
        var canvas = Canvas(width: 60, height: 40, fill: black)
        let rect = IntRect(x: 10, y: 8, width: 30, height: 20)
        canvas.stroke(rect, color: magenta, lineWidth: 2)
        canvas.erase(corners: 4, of: rect, to: black)
        #expect(canvas.image.edgeCoverage(of: rect, color: magenta, tolerance: 0)?.minimum ?? 1 < 1)
        let inset = canvas.image.edgeCoverage(
            of: rect, color: magenta, tolerance: 0, inset: 5)
        #expect(inset?.minimum == 1.0)
    }

    /// ずれを見逃さないことが肝。位置がずれた枠線を「出ている」と報告すると、
    /// 配置計算の誤りを取り逃がす。
    @Test("位置がずれていれば一致が落ちる")
    func misplacedBorder() {
        var canvas = Canvas(width: 60, height: 40, fill: black)
        canvas.stroke(IntRect(x: 14, y: 8, width: 30, height: 20), color: magenta, lineWidth: 1)
        // 端を切るのは、ずれた矩形の上下の辺が縦の辺と交差する点を数えないため。
        let coverage = canvas.image.edgeCoverage(
            of: IntRect(x: 10, y: 8, width: 30, height: 20), color: magenta, tolerance: 0, inset: 2)
        // 左右の辺は 4pt ずれているので乗っていない。
        #expect(coverage?.left == 0)
        #expect(coverage?.right == 0)
    }

    /// 反エイリアスで線が隣の行にはみ出すことがある。1画素だけ厳密に見ると
    /// 描かれているのに落ちる。**線幅の帯として見る。**
    @Test("1画素ずれても線幅の帯なら拾う")
    func lineWidthBand() {
        var canvas = Canvas(width: 60, height: 40, fill: black)
        let expected = IntRect(x: 10, y: 8, width: 30, height: 20)
        canvas.stroke(IntRect(x: 11, y: 9, width: 30, height: 20), color: magenta, lineWidth: 1)
        #expect(canvas.image.edgeCoverage(of: expected, color: magenta, tolerance: 0)?.top == 0)
        let banded = canvas.image.edgeCoverage(
            of: expected, color: magenta, tolerance: 0, lineWidth: 2, inset: 2)
        #expect((banded?.top ?? 0) > 0.9)
    }

    @Test("画像からはみ出す矩形は判定不能として返す")
    func edgeCoverageOutOfBounds() {
        let canvas = Canvas(width: 20, height: 20, fill: black)
        #expect(
            canvas.image.edgeCoverage(
                of: IntRect(x: 15, y: 15, width: 10, height: 10), color: magenta, tolerance: 0)
                == nil)
    }

    // MARK: - 差分

    @Test("同じ画像なら差は無い")
    func identicalImages() {
        let a = Canvas(width: 10, height: 10, fill: black).image
        let b = Canvas(width: 10, height: 10, fill: black).image
        let diff = a.differingPixels(from: b, tolerance: 0)
        #expect(diff?.count == 0)
        #expect(diff?.total == 100)
    }

    @Test("違う画素だけを数える")
    func countsDifferences() {
        let a = Canvas(width: 10, height: 10, fill: black).image
        var canvas = Canvas(width: 10, height: 10, fill: black)
        canvas.set(x: 4, y: 4, to: magenta)
        canvas.set(x: 5, y: 4, to: magenta)
        #expect(a.differingPixels(from: canvas.image, tolerance: 0)?.count == 2)
    }

    /// HUD は画面中央にしか出ない。全画面で差を見ると、時計の分表示や
    /// 動いているウィンドウの中身まで拾って判定にならない。
    @Test("範囲を限れば外側の違いは数えない")
    func regionLimitsDiff() {
        let a = Canvas(width: 20, height: 20, fill: black).image
        var canvas = Canvas(width: 20, height: 20, fill: black)
        canvas.set(x: 1, y: 1, to: magenta)  // 範囲の外
        canvas.set(x: 12, y: 12, to: magenta)  // 範囲の中
        let diff = a.differingPixels(
            from: canvas.image, tolerance: 0, in: IntRect(x: 10, y: 10, width: 5, height: 5))
        #expect(diff?.count == 1)
        #expect(diff?.total == 25)
    }

    /// 影の揺らぎや壁紙の圧縮ノイズで毎回数画素は変わる。
    /// 許容差を持たせないと「変わっていない」を判定できない。
    @Test("許容差以下の違いは数えない")
    func diffTolerance() {
        let a = Canvas(width: 10, height: 10, fill: black).image
        var canvas = Canvas(width: 10, height: 10, fill: black)
        canvas.set(x: 0, y: 0, to: PixelColor(red: 4, green: 0, blue: 0))
        #expect(a.differingPixels(from: canvas.image, tolerance: 6)?.count == 0)
        #expect(a.differingPixels(from: canvas.image, tolerance: 2)?.count == 1)
    }

    /// 撮り方を間違えて大きさの違う画像を比べたときに、0 と報告されると
    /// 「変わらなかった」と誤読してしまう。**判定不能として返す。**
    @Test("大きさが違う画像は比べられない")
    func mismatchedSizes() {
        let a = Canvas(width: 10, height: 10, fill: black).image
        let b = Canvas(width: 10, height: 11, fill: black).image
        #expect(a.differingPixels(from: b, tolerance: 0) == nil)
    }

    @Test("画像の外にはみ出す範囲は判定不能として返す")
    func regionOutOfBounds() {
        let a = Canvas(width: 10, height: 10, fill: black).image
        let b = Canvas(width: 10, height: 10, fill: black).image
        #expect(
            a.differingPixels(from: b, tolerance: 0, in: IntRect(x: 8, y: 8, width: 5, height: 5))
                == nil)
        #expect(a.boundingBox(matching: magenta, tolerance: 0, in: IntRect(x: -1, y: 0, width: 2, height: 2)) == nil)
    }

    // MARK: - 色の綴り

    @Test("設定と同じ綴りで色を書ける")
    func hexParsing() {
        #expect(PixelColor(hex: "#ff00ff") == magenta)
        #expect(PixelColor(hex: "ff00ff") == magenta)
        #expect(PixelColor(hex: "#FF00FF") == magenta)
        #expect(PixelColor(hex: "#7aa2f7") == PixelColor(red: 0x7a, green: 0xa2, blue: 0xf7))
        #expect(PixelColor(hex: "#fff") == nil)
        #expect(PixelColor(hex: "zzzzzz") == nil)
    }
}

/// テスト用の描画。実際の撮影を挟まずに画素の並びを組み立てる。
fileprivate struct Canvas {

    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, fill: PixelColor) {
        self.width = width
        self.height = height
        self.bytes = []
        bytes.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            bytes.append(contentsOf: [fill.red, fill.green, fill.blue, 255])
        }
    }

    var image: PixelImage { PixelImage(width: width, height: height, bytes: bytes) }

    mutating func set(x: Int, y: Int, to color: PixelColor, alpha: UInt8 = 255) {
        let offset = (y * width + x) * 4
        bytes[offset] = color.red
        bytes[offset + 1] = color.green
        bytes[offset + 2] = color.blue
        bytes[offset + 3] = alpha
    }

    /// 矩形を塗る。
    mutating func fill(_ rect: IntRect, color: PixelColor) {
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) { set(x: x, y: y, to: color) }
        }
    }

    /// 四隅の正方形を塗り消す。角丸で円弧になり、辺の直線上から外れる部分を模す。
    mutating func erase(corners size: Int, of rect: IntRect, to color: PixelColor) {
        for (originX, originY) in [
            (rect.x, rect.y), (rect.x + rect.width - size, rect.y),
            (rect.x, rect.y + rect.height - size),
            (rect.x + rect.width - size, rect.y + rect.height - size),
        ] {
            for y in originY..<(originY + size) {
                for x in originX..<(originX + size) { set(x: x, y: y, to: color) }
            }
        }
    }

    /// 縁だけを描く。枠線と同じ形にするため中は塗らない。
    mutating func stroke(_ rect: IntRect, color: PixelColor, lineWidth: Int) {
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) {
                let onEdge =
                    x < rect.x + lineWidth || x >= rect.x + rect.width - lineWidth
                    || y < rect.y + lineWidth || y >= rect.y + rect.height - lineWidth
                if onEdge { set(x: x, y: y, to: color) }
            }
        }
    }
}

/// 画像の余白を落とす（アイコンの切り出しに使う）。
///
/// 生成画像は周りに余白と影が付いてくる。**アプリのアイコンにするには
/// 図形そのものの範囲へ切り詰める**必要がある。
@Suite("余白の検出")
struct ContentBoundsTests {

    private let white = PixelColor(red: 255, green: 255, blue: 255)
    private let navy = PixelColor(red: 32, green: 32, blue: 96)

    @Test("背景だけの画像には中身が無い")
    func nothingButBackground() {
        let canvas = Canvas(width: 20, height: 20, fill: white)
        #expect(canvas.image.contentBounds(background: white, tolerance: 8) == nil)
    }

    @Test("中身の範囲を返す")
    func findsContent() {
        var canvas = Canvas(width: 40, height: 30, fill: white)
        canvas.fill(IntRect(x: 10, y: 8, width: 12, height: 9), color: navy)
        #expect(
            canvas.image.contentBounds(background: white, tolerance: 8)
                == IntRect(x: 10, y: 8, width: 12, height: 9))
    }

    /// **影を含めてはいけない。** 生成画像の影は背景から数〜十数しか違わないので、
    /// 許容差を上げれば図形だけが残る。
    @Test("許容差を上げると薄い影を含めない")
    func excludesFaintShadow() {
        var canvas = Canvas(width: 40, height: 30, fill: white)
        // 図形の周りに薄い影（白から 12 だけ違う）
        canvas.fill(IntRect(x: 8, y: 6, width: 16, height: 13), color: PixelColor(red: 243, green: 243, blue: 243))
        canvas.fill(IntRect(x: 10, y: 8, width: 12, height: 9), color: navy)

        #expect(
            canvas.image.contentBounds(background: white, tolerance: 6)
                == IntRect(x: 8, y: 6, width: 16, height: 13), "許容差が小さいと影まで含む")
        #expect(
            canvas.image.contentBounds(background: white, tolerance: 40)
                == IntRect(x: 10, y: 8, width: 12, height: 9), "許容差を上げれば図形だけ")
    }

    // MARK: - 正方形へ

    @Test("正方形へ広げる（中心を保つ）")
    func expandsToSquare() {
        let rect = IntRect(x: 10, y: 20, width: 40, height: 20)
        let square = rect.squared(within: IntRect(x: 0, y: 0, width: 100, height: 100))
        #expect(square.width == square.height)
        #expect(square.width == 40)
        #expect(square.x == 10, "横はそのまま")
        #expect(square.y == 10, "縦は中心を保って広がる")
    }

    /// 画像の外へはみ出さない。はみ出すと切り出しが失敗する。
    @Test("画像の外へはみ出さないよう寄せる")
    func squareStaysInsideBounds() {
        let bounds = IntRect(x: 0, y: 0, width: 100, height: 50)
        let square = IntRect(x: 90, y: 10, width: 8, height: 30).squared(within: bounds)
        #expect(square.width == square.height)
        #expect(square.isInside(bounds) || square == bounds)
    }

    @Test("既に正方形なら変わらない")
    func alreadySquare() {
        let rect = IntRect(x: 5, y: 5, width: 20, height: 20)
        #expect(rect.squared(within: IntRect(x: 0, y: 0, width: 50, height: 50)) == rect)
    }
}

/// アイコン用に背景を落とす。
///
/// **色で一律に判定してはいけない。** 図形の中に背景と近い色（白いグロウなど）が
/// あると、そこまで抜けて穴が空く。**外周から繋がっている部分だけ**を背景とみなす。
@Suite("背景の除去")
struct BackgroundRemovalTests {

    private let white = PixelColor(red: 250, green: 250, blue: 250)
    private let navy = PixelColor(red: 32, green: 32, blue: 96)

    @Test("外周から繋がった背景を落とす")
    func removesOuterBackground() {
        var canvas = Canvas(width: 10, height: 10, fill: white)
        canvas.fill(IntRect(x: 3, y: 3, width: 4, height: 4), color: navy)
        let mask = canvas.image.backgroundMask(tolerance: 20)
        #expect(mask?.contains(0) == true, "左上は背景")
        #expect(mask?.contains(3 * 10 + 3) == false, "図形の中は残す")
    }

    /// 図形の中の明るい部分（グロウ）は背景と近い色でも**外周と繋がっていない**ので残る。
    @Test("図形の中の明るい部分は落とさない")
    func keepsEnclosedHighlight() {
        var canvas = Canvas(width: 12, height: 12, fill: white)
        canvas.fill(IntRect(x: 2, y: 2, width: 8, height: 8), color: navy)
        // 図形の中央に背景と同じ色の点（グロウのつもり）
        canvas.set(x: 6, y: 6, to: white)
        let mask = canvas.image.backgroundMask(tolerance: 20)
        #expect(mask?.contains(6 * 12 + 6) == false, "囲まれている明るい点は残す")
    }

    /// **余白の無い画像に掛けたときに絵を丸ごと消してはいけない。**
    /// 全面が背景と判定されたら「落とすものが無い」とみなす。
    @Test("全面が背景と判定されたら何も落とさない")
    func uniformImageKeepsEverything() {
        #expect(Canvas(width: 5, height: 5, fill: white).image.backgroundMask(tolerance: 20)?.isEmpty == true)
        #expect(Canvas(width: 5, height: 5, fill: navy).image.backgroundMask(tolerance: 20)?.isEmpty == true)
    }
}
