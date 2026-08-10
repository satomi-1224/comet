import Foundation
import Testing
import CometCore

@testable import CometDecoration

/// 壁紙のパス解決。**症状D の対策の入口。**
///
/// 切替のたびにファイルの存在を確かめるのは無駄なので、検証は起動時に一度だけ行う。
/// その「一度だけ」の判定をここで固める。
@Suite("WallpaperService")
struct WallpaperServiceTests {

    // MARK: - 存在の検証

    @Test("実在するパスだけが残る")
    func keepsOnlyExistingFiles() {
        let resolved = WallpaperService.resolve(
            [1: "/a/one.jpg", 2: "/a/missing.jpg", 3: "/a/three.jpg"],
            fileExists: { $0 != "/a/missing.jpg" })

        #expect(Set(resolved.urls.keys) == [1, 3])
        #expect(resolved.missing == [2: "/a/missing.jpg"])
        #expect(resolved.urls[1]?.path == "/a/one.jpg")
    }

    @Test("空のパスは無いものとして扱う")
    func emptyPathIsMissing() {
        let resolved = WallpaperService.resolve([1: "", 2: "   "], fileExists: { _ in true })
        #expect(resolved.urls.isEmpty)
        #expect(resolved.missing.count == 2)
    }

    @Test("何も設定されていなければ空")
    func emptyInput() {
        let resolved = WallpaperService.resolve([:], fileExists: { _ in true })
        #expect(resolved.urls.isEmpty)
        #expect(resolved.missing.isEmpty)
    }

    // MARK: - パスの展開

    @Test("先頭の ~ をホームへ展開する")
    func expandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(WallpaperService.expand("~/Pictures/a.jpg") == "\(home)/Pictures/a.jpg")
        #expect(WallpaperService.expand("~") == home)
    }

    @Test("途中の ~ は展開しない")
    func doesNotExpandMidPath() {
        #expect(WallpaperService.expand("/a/~/b.jpg") == "/a/~/b.jpg")
        #expect(WallpaperService.expand("~user/a.jpg") == "~user/a.jpg", "~user 形式は扱わない")
    }

    @Test("前後の空白を落とす")
    func trimsWhitespace() {
        #expect(WallpaperService.expand("  /a/b.jpg  ") == "/a/b.jpg")
    }

    @Test("展開したパスで存在を確かめる")
    func checksExpandedPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var asked: [String] = []
        _ = WallpaperService.resolve(
            [1: "~/wall.jpg"],
            fileExists: { path in
                asked.append(path)
                return true
            })
        #expect(asked == ["\(home)/wall.jpg"])
    }

    // MARK: - 実ファイルでの往復

    @Test("実在するファイルを登録できる")
    func loadsRealFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("comet-wallpaper-test", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("one.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)

        let resolved = WallpaperService.resolve([1: file.path, 2: directory.path + "/none.png"])
        #expect(resolved.urls.keys.sorted() == [1])
        #expect(resolved.missing.keys.sorted() == [2])
    }
}
