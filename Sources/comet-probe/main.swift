import AppKit
import CometProbe
import CoreGraphics
import Dispatch
import Foundation

/// 画面の実測を読む検証専用の道具。
///
/// これがあるのは、**「目視でしか判定できない」項目を機械に判定させる**ため。
/// 枠線や HUD が出ているかは撮った画像の画素で、ウィンドウが本当にその位置に
/// 居るかはウィンドウ一覧で確かめられる。
///
/// 撮影そのものは `screencapture` に任せている。画面収録の権限を comet 側に
/// 要求しないため（端末が既に持っている権限で撮った PNG をここが読む）。
///
/// 出力は `key=value` を空白で区切った1行。bash から拾いやすい形にしてある。
/// 値が空白を含みうる `owner=` は必ず行末に置く。

let usage = """
    comet-probe — 画面の実測（検証専用）

    使い方: comet-probe <サブコマンド> [オプション]

    画像を読む:
      size <png>
          画像の大きさ。撮影の倍率（画素/pt）を求めるのに使う。
          → w= h=

      color <png> <x,y>
          その位置の色。
          → color=#rrggbb

      bbox <png> <#rrggbb> [--tolerance n] [--region x,y,w,h]
          その色が描かれている範囲。一致した画素すべてを囲むので、
          位置の判定には edges を使う（画面の別の場所への写り込みを拾う）。
          → x= y= w= h= count=  （一致が無ければ空で終了コード 1）

      edges <png> <#rrggbb> --rect x,y,w,h [--tolerance n] [--line-width n] [--inset n]
          その矩形の四辺に色がどれだけ乗っているか（百分率）。枠線の判定用。
          --inset は角丸の半径より少し大きく取る（円弧は辺の直線上に無い）。
          → top= bottom= left= right= min=

      diff <a.png> <b.png> [--tolerance n] [--region x,y,w,h]
          変わった画素の数。HUD やメニューバーの表示は差分で捉える。
          → differing= total= permille=

      trim <png> [--tolerance n] [--square]
          背景（四隅の色）と違う部分の範囲。アイコンの切り出しに使う。
          --square で中心を保ったまま正方形へ広げる。
          → x= y= w= h=

    画像を作る:
      crop <入力png> <出力png> <x,y,w,h> [--size n]
          切り出して書き出す。--size で正方形に伸縮する（アイコン用）。
          → 書き出したパス

      icon <入力png> <出力png> [--tolerance n] [--size n]
          アプリのアイコン用に切り出す。**外周から繋がった背景を透明にし**、
          残った部分の正方形へ切り詰めて伸縮する（既定 1024）。
          → 書き出したパス と 切り出した範囲

      solid <png> <幅x高さ> <#rrggbb>
          単色の PNG を書き出す。壁紙の切替を色で判定するための検証用。
          → 書き出したパス

    画面とウィンドウを読む:
      screen
          画面の大きさと表示領域（左上原点・pt）。
          → w= h= visible-x= visible-y= visible-w= visible-h=

      displays
          全ディスプレイの位置と大きさ（左上原点・pt）。1行1台。
          → id= x= y= w= h= primary=yes|no

      windows [--owner name] [--layer n] [--min-area n]
          画面に出ているウィンドウの実座標。
          → id= layer= x= y= w= h= owner=

      watch --ms n [--interval-ms n] [--owner name] [--new] [--min-area n]
            [--tolerance n] [--samples]
          ウィンドウの矩形を追い、落ち着くまでの様子を要約する（症状A の計測）。
          --new を付けると、追跡を始めたあとに現れたウィンドウだけを見る。
          → summary id= appeared-ms= distinct= settle-ms= other-ms=
                    first-pos-ms= first-x= … final-h= owner=
          first-pos-ms が症状A の実体（現れた位置から動き出すまで）。
          settle-ms と other-ms はアプリの表示アニメーションを含む。
    """

// MARK: - 引数

/// `--name value` と `--name=value` の両方を受ける単純な解釈。
struct Arguments {
    private var options: [String: String] = [:]
    private(set) var positionals: [String] = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                index += 1
                continue
            }
            let name = String(argument.dropFirst(2))
            if let equals = name.firstIndex(of: "=") {
                options[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
                index += 1
                continue
            }
            let next = index + 1 < raw.count ? raw[index + 1] : nil
            if let next, !next.hasPrefix("--") {
                options[name] = next
                index += 2
            } else {
                options[name] = ""  // 値を取らない旗
                index += 1
            }
        }
    }

    func string(_ name: String) -> String? { options[name] }
    func has(_ name: String) -> Bool { options[name] != nil }
    func int(_ name: String, default fallback: Int) -> Int {
        guard let text = options[name], let value = Int(text) else { return fallback }
        return value
    }
    func rect(_ name: String) -> IntRect? {
        guard let text = options[name] else { return nil }
        return IntRect(commaSeparated: text)
    }
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("comet-probe: \(message)\n".utf8))
    exit(code)
}

/// 割合を百分率の整数で出す。bash に小数を渡すと比較できない。
func percent(_ ratio: Double) -> Int { Int((ratio * 100).rounded()) }

// MARK: - 画像

func loadImage(_ path: String) -> PixelImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        fail("画像を読めない: \(path)")
    }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        fail("画像の大きさが不正: \(path)")
    }

    // **撮った画像は P3 で保存されている**ことがある。sRGB の文脈へ描き直して
    // 色空間を揃えてから比べる（設定に書いた #rrggbb は sRGB のつもりの値）。
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { fail("画像を展開できない: \(path)") }
    return PixelImage(width: width, height: height, bytes: bytes)
}

func requireColor(_ text: String?) -> PixelColor {
    guard let text, let color = PixelColor(hex: text) else {
        fail("色は #rrggbb の形で指定する: \(text ?? "（無し）")")
    }
    return color
}

// MARK: - ウィンドウ

struct WindowInfo {
    let id: Int
    let layer: Int
    let owner: String
    let alpha: Double
    let rect: IntRect
}

/// 画面に出ているウィンドウ。
///
/// 位置と大きさは画面収録の権限が無くても読める（題名だけは読めない）。
/// アクセシビリティ権限にも依存しないので、comet とは独立した観測になる。
func onScreenWindows() -> [WindowInfo] {
    let raw =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return raw.compactMap { entry in
        guard let id = entry[kCGWindowNumber as String] as? Int,
            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
            let x = bounds["X"], let y = bounds["Y"],
            let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }
        return WindowInfo(
            id: id,
            layer: entry[kCGWindowLayer as String] as? Int ?? 0,
            owner: entry[kCGWindowOwnerName as String] as? String ?? "?",
            alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
            rect: IntRect(
                x: Int(x.rounded()), y: Int(y.rounded()),
                width: Int(width.rounded()), height: Int(height.rounded())))
    }
}

/// 観測の対象を絞る。
///
/// 既定で `layer=0`（通常のウィンドウ）だけを見る。枠線や HUD は別の階層に
/// 居るので、アプリのウィンドウを数えるときに混ざらないようにする。
func filtered(_ windows: [WindowInfo], _ arguments: Arguments) -> [WindowInfo] {
    let owner = arguments.string("owner")
    let layer = arguments.has("any-layer") ? nil : arguments.int("layer", default: 0)
    let minimumArea = arguments.int("min-area", default: 0)
    return windows.filter { window in
        if let owner, window.owner != owner { return false }
        if let layer, window.layer != layer { return false }
        if window.rect.width * window.rect.height < minimumArea { return false }
        // 透明なウィンドウは見えていない。ちらつきの判定に混ぜてはいけない。
        return window.alpha > 0
    }
}

func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

// MARK: - 実行

let raw = Array(CommandLine.arguments.dropFirst())
guard let subcommand = raw.first, !subcommand.hasPrefix("-") else {
    print(usage)
    exit(raw.isEmpty ? 2 : 0)
}
let arguments = Arguments(Array(raw.dropFirst()))

switch subcommand {

case "help", "--help", "-h":
    print(usage)

case "size":
    guard let path = arguments.positionals.first else { fail("画像を指定する") }
    let image = loadImage(path)
    print("w=\(image.width) h=\(image.height)")

case "color":
    guard arguments.positionals.count >= 2 else { fail("comet-probe color <png> <x,y>") }
    let image = loadImage(arguments.positionals[0])
    let parts = arguments.positionals[1].split(separator: ",").compactMap { Int($0) }
    guard parts.count == 2 else { fail("位置は x,y の形で指定する") }
    guard let color = image.color(x: parts[0], y: parts[1]) else { fail("画像の外を指している") }
    print("color=\(color)")

case "bbox":
    guard arguments.positionals.count >= 2 else { fail("comet-probe bbox <png> <#rrggbb>") }
    let image = loadImage(arguments.positionals[0])
    let color = requireColor(arguments.positionals[1])
    guard
        let match = image.boundingBox(
            matching: color, tolerance: arguments.int("tolerance", default: 16),
            in: arguments.rect("region"))
    else {
        FileHandle.standardError.write(Data("comet-probe: \(color) の画素が無い\n".utf8))
        exit(1)
    }
    print(
        "x=\(match.rect.x) y=\(match.rect.y) w=\(match.rect.width) h=\(match.rect.height) "
            + "count=\(match.count)")

case "edges":
    guard arguments.positionals.count >= 2 else {
        fail("comet-probe edges <png> <#rrggbb> --rect x,y,w,h")
    }
    let image = loadImage(arguments.positionals[0])
    let color = requireColor(arguments.positionals[1])
    guard let rect = arguments.rect("rect") else { fail("--rect x,y,w,h を指定する") }
    guard
        let coverage = image.edgeCoverage(
            of: rect, color: color, tolerance: arguments.int("tolerance", default: 16),
            lineWidth: arguments.int("line-width", default: 1),
            inset: arguments.int("inset", default: 0))
    else {
        fail("判定できない（矩形 \(rect) が画像 \(image.width)x\(image.height) の外）", code: 3)
    }
    print(
        "top=\(percent(coverage.top)) bottom=\(percent(coverage.bottom)) "
            + "left=\(percent(coverage.left)) right=\(percent(coverage.right)) "
            + "min=\(percent(coverage.minimum))")

case "diff":
    guard arguments.positionals.count >= 2 else { fail("comet-probe diff <a.png> <b.png>") }
    let before = loadImage(arguments.positionals[0])
    let after = loadImage(arguments.positionals[1])
    guard
        let diff = after.differingPixels(
            from: before, tolerance: arguments.int("tolerance", default: 12),
            in: arguments.rect("region"))
    else {
        fail("比べられない（大きさが違う、または範囲が画像の外）", code: 3)
    }
    let permille = diff.total > 0 ? diff.count * 1000 / diff.total : 0
    print("differing=\(diff.count) total=\(diff.total) permille=\(permille)")

case "trim":
    guard let path = arguments.positionals.first else { fail("comet-probe trim <png>") }
    let image = loadImage(path)
    // 背景は四隅の色とみなす。生成画像の余白はほぼ均一なのでこれで足りる。
    guard let background = image.color(x: 0, y: 0) else { fail("画像を読めない") }
    guard
        let content = image.contentBounds(
            background: background, tolerance: arguments.int("tolerance", default: 24))
    else {
        fail("背景しか無い（\(background) 一色）", code: 1)
    }
    let result = arguments.has("square") ? content.squared(within: image.bounds) : content
    print("x=\(result.x) y=\(result.y) w=\(result.width) h=\(result.height)")

case "crop":
    guard arguments.positionals.count >= 3 else {
        fail("comet-probe crop <入力png> <出力png> <x,y,w,h>")
    }
    guard let rect = IntRect(commaSeparated: arguments.positionals[2]) else {
        fail("範囲は x,y,w,h の形で指定する")
    }
    guard let source = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: arguments.positionals[0]) as CFURL, nil),
        let full = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("画像を読めない: \(arguments.positionals[0])") }
    guard let cropped = full.cropping(
        to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    else { fail("切り出せない（範囲が画像の外）") }

    var output = cropped
    let side = arguments.int("size", default: 0)
    if side > 0 {
        guard let space = cropped.colorSpace,
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fail("伸縮できない") }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { fail("伸縮できない") }
        output = scaled
    }
    guard let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments.positionals[1]) as CFURL, "public.png" as CFString, 1, nil)
    else { fail("書き出せない") }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else { fail("書き出せない") }
    print(arguments.positionals[1])

case "icon":
    guard arguments.positionals.count >= 2 else {
        fail("comet-probe icon <入力png> <出力png>")
    }
    let source = loadImage(arguments.positionals[0])
    let keyTolerance = arguments.int("tolerance", default: 24)
    guard let mask = source.backgroundMask(tolerance: keyTolerance) else {
        fail("画像を読めない: \(arguments.positionals[0])")
    }

    // 背景を透明にした画素の並びを作る。
    var bytes = source.bytes
    for index in mask {
        let offset = index * 4
        guard offset + 3 < bytes.count else { continue }
        bytes[offset + 3] = 0
    }

    // 残った部分（不透明な画素）の範囲へ切り詰め、正方形に整える。
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    for y in 0..<source.height {
        for x in 0..<source.width where !mask.contains(y * source.width + x) {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    guard minX <= maxX else { fail("背景しか無い") }
    let content = IntRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    let square = content.squared(within: source.bounds)

    // 透明を保てる形式（premultipliedLast）で描き直して書き出す。
    let side = arguments.int("size", default: 1024)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("色空間を作れない") }
    var cutout: CGImage?
    bytes.withUnsafeMutableBytes { buffer in
        guard
            let context = CGContext(
                data: buffer.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        cutout = context.makeImage()
    }
    guard
        let whole = cutout,
        let cropped = whole.cropping(
            to: CGRect(x: square.x, y: square.y, width: square.width, height: square.height)),
        let output = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("切り出せない") }
    output.interpolationQuality = .high
    output.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let scaled = output.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: arguments.positionals[1]) as CFURL, "public.png" as CFString, 1,
            nil)
    else { fail("書き出せない") }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else { fail("書き出せない") }
    print("\(arguments.positionals[1]) 切り出し=\(square) 透明にした画素=\(mask.count)")

case "solid":
    // 壁紙の判定を「その色が出ているか」で行えるようにする。写真では
    // 拡大や切り抜きの影響を受けるが、単色なら埋め方に関係なく同じ色になる。
    guard arguments.positionals.count >= 3 else {
        fail("comet-probe solid <png> <幅x高さ> <#rrggbb>")
    }
    let size = arguments.positionals[1].lowercased().split(separator: "x").compactMap { Int($0) }
    guard size.count == 2, size[0] > 0, size[1] > 0 else { fail("大きさは 幅x高さ の形で指定する") }
    let fill = requireColor(arguments.positionals[2])
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: size[0], height: size[1], bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fail("画像を作れない") }
    context.setFillColor(
        red: CGFloat(fill.red) / 255, green: CGFloat(fill.green) / 255,
        blue: CGFloat(fill.blue) / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size[0], height: size[1]))
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: arguments.positionals[0]) as CFURL, "public.png" as CFString, 1,
            nil)
    else { fail("画像を書き出せない") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("画像を書き出せない") }
    print(arguments.positionals[0])

case "screen":
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { fail("画面が無い") }
    // AppKit（左下原点）→ CG/AX（左上原点）。comet の内部状態と同じ向きに揃える。
    let height = screen.frame.height
    let visible = screen.visibleFrame
    let visibleTop = height - (visible.origin.y + visible.height)
    print(
        "w=\(Int(screen.frame.width)) h=\(Int(height)) "
            + "visible-x=\(Int(visible.origin.x)) visible-y=\(Int(visibleTop)) "
            + "visible-w=\(Int(visible.width)) visible-h=\(Int(visible.height))")

case "displays":
    // サブディスプレイの検証は2台目が繋がっていないと成立しない。台数を機械で見る。
    let height = (NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
    for (index, screen) in NSScreen.screens.enumerated() {
        // AppKit（左下原点）→ CG/AX（左上原点）。comet の内部と同じ向きに揃える。
        let frame = screen.frame
        let top = height - frame.maxY
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        print(
            "id=\(number?.uint32Value ?? UInt32(index)) x=\(Int(frame.minX)) y=\(Int(top)) "
                + "w=\(Int(frame.width)) h=\(Int(frame.height)) "
                + "primary=\(index == 0 ? "yes" : "no")")
    }

case "windows":
    for window in filtered(onScreenWindows(), arguments).sorted(by: { $0.rect.x < $1.rect.x }) {
        print(
            "id=\(window.id) layer=\(window.layer) x=\(window.rect.x) y=\(window.rect.y) "
                + "w=\(window.rect.width) h=\(window.rect.height) owner=\(window.owner)")
    }

case "watch":
    let duration = arguments.int("ms", default: 1500)
    let interval = arguments.int("interval-ms", default: 8)
    let tolerance = arguments.int("tolerance", default: 2)
    let newOnly = arguments.has("new")
    let printSamples = arguments.has("samples")

    // comet のログと突き合わせられるように、開始の壁時計を同じ書式で出す。
    // 「通知が来るまで」と「適用に掛かる」を切り分けるにはこれが要る。
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss.SSS"
    clock.locale = Locale(identifier: "en_US_POSIX")
    print("start clock=\(clock.string(from: Date()))")

    let start = nowMs()
    // **追跡開始時に居たものの集合は書き換えない。** 現れたウィンドウをここへ
    // 足してしまうと、2回目以降の観測が「元から居た」として飛ばされ、
    // 1点しか記録されない（現れた位置＝落ち着いた位置に見えてしまう）。
    let initial = Set(filtered(onScreenWindows(), arguments).map(\.id))
    var samples: [Int: [WindowSample]] = [:]
    var owners: [Int: String] = [:]
    var appeared: [Int: Int] = [:]

    while nowMs() - start < duration {
        let elapsed = nowMs() - start
        for window in filtered(onScreenWindows(), arguments) {
            if newOnly, initial.contains(window.id) { continue }
            if appeared[window.id] == nil {
                appeared[window.id] = elapsed
            }
            owners[window.id] = window.owner
            samples[window.id, default: []].append(
                WindowSample(elapsedMs: elapsed, rect: window.rect))
            if printSamples {
                print(
                    "sample id=\(window.id) ms=\(elapsed) x=\(window.rect.x) y=\(window.rect.y) "
                        + "w=\(window.rect.width) h=\(window.rect.height)")
            }
        }
        usleep(UInt32(max(1, interval) * 1000))
    }

    for (id, history) in samples.sorted(by: { $0.key < $1.key }) {
        guard let summary = WindowHistory.summarize(history, tolerance: tolerance) else { continue }
        print(
            "summary id=\(id) appeared-ms=\(appeared[id] ?? 0) "
                + "distinct=\(summary.distinctPositions) settle-ms=\(summary.msToSettle) "
                + "other-ms=\(summary.msAtOtherPositions) "
                + "first-pos-ms=\(summary.msAtFirstPosition) samples=\(history.count) "
                + "first-x=\(summary.firstRect.x) first-y=\(summary.firstRect.y) "
                + "first-w=\(summary.firstRect.width) first-h=\(summary.firstRect.height) "
                + "final-x=\(summary.finalRect.x) final-y=\(summary.finalRect.y) "
                + "final-w=\(summary.finalRect.width) final-h=\(summary.finalRect.height) "
                + "owner=\(owners[id] ?? "?")")
    }

default:
    fail("未知のサブコマンド: \(subcommand)\n\n\(usage)")
}
