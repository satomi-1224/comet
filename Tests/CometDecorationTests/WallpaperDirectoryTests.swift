import Foundation
import Testing
import CometCore

@testable import CometDecoration

/// ディレクトリを1つ指定するだけでワークスペースごとの壁紙が決まるようにする。
///
/// 1枚ずつパスを書くのは、ワークスペースが10個あると現実的でない。
/// **名前順に取って、足りなければ先頭から繰り返す**（3枚なら 1231231231）。
///
/// 変えないほうを既定にする。ディレクトリが無い・画像が1枚も無いときに
/// 中途半端に壁紙を変えると、利用者から見て「勝手に変わった」だけになる。
@Suite("壁紙のディレクトリ指定")
struct WallpaperDirectoryTests {

    /// ディレクトリの中身を差し替えて割り当てを見る。
    private func plan(
        _ names: [String]?, workspaces: Int = 10, directory: String = "/wall"
    ) -> [WorkspaceID: String] {
        WallpaperService.plan(
            directory: directory, workspaceCount: workspaces, contents: { _ in names })
    }

    // MARK: - 並び順

    /// 「名前順」は Finder の並びと同じ自然順にする。
    /// 辞書順だと wallpaper10 が wallpaper2 より前に来て、利用者の意図とずれる。
    @Test("番号は数として並べる")
    func naturalOrder() {
        let assigned = plan(["wallpaper10.png", "wallpaper2.png", "wallpaper1.png"], workspaces: 3)
        #expect(assigned[1] == "/wall/wallpaper1.png")
        #expect(assigned[2] == "/wall/wallpaper2.png")
        #expect(assigned[3] == "/wall/wallpaper10.png")
    }

    @Test("画像以外は数に入れない")
    func ignoresNonImages() {
        let assigned = plan(["a.png", "memo.txt", "b.jpg", "Thumbs.db"], workspaces: 2)
        #expect(assigned[1] == "/wall/a.png")
        #expect(assigned[2] == "/wall/b.jpg")
    }

    @Test("隠しファイルは数に入れない")
    func ignoresHiddenFiles() {
        let assigned = plan([".DS_Store", ".hidden.png", "a.png"], workspaces: 2)
        #expect(assigned[1] == "/wall/a.png")
        #expect(assigned[2] == "/wall/a.png")
    }

    @Test("拡張子の大文字小文字は問わない")
    func caseInsensitiveExtensions() {
        let assigned = plan(["A.PNG", "b.JPEG", "c.HEIC"], workspaces: 3)
        #expect(assigned.count == 3)
        #expect(assigned[1] == "/wall/A.PNG")
    }

    // MARK: - 割り当て

    @Test("ワークスペースの数だけ名前順に採る")
    func takesUpToWorkspaceCount() {
        let names = (1...12).map { "w\($0).png" }
        let assigned = plan(names, workspaces: 10)
        #expect(assigned.count == 10)
        #expect(assigned[10] == "/wall/w10.png")
        // 11枚目以降は使わない
        #expect(!assigned.values.contains("/wall/w11.png"))
    }

    /// 利用者の指定そのもの。3枚なら 1231231231 の順で埋める。
    @Test("足りなければ先頭から繰り返す")
    func cyclesWhenFewerImages() {
        let assigned = plan(["a.png", "b.png", "c.png"], workspaces: 10)
        let expected = [
            1: "a", 2: "b", 3: "c", 4: "a", 5: "b", 6: "c", 7: "a", 8: "b", 9: "c", 10: "a",
        ]
        for (workspace, name) in expected {
            #expect(assigned[workspace] == "/wall/\(name).png", "ws\(workspace)")
        }
    }

    @Test("1枚だけなら全てのワークスペースで同じ")
    func singleImage() {
        let assigned = plan(["only.png"], workspaces: 4)
        #expect(assigned.count == 4)
        #expect(Set(assigned.values) == ["/wall/only.png"])
    }

    // MARK: - 変えない場合

    @Test("画像が1枚も無ければ何も割り当てない")
    func noImages() {
        #expect(plan(["memo.txt"]).isEmpty)
        #expect(plan([]).isEmpty)
    }

    /// 読めないディレクトリ（存在しない・指定が空）では**壁紙を変えない**。
    @Test("ディレクトリが無ければ何も割り当てない")
    func missingDirectory() {
        #expect(plan(nil).isEmpty)
        #expect(WallpaperService.plan(directory: "", workspaceCount: 10, contents: { _ in ["a.png"] }).isEmpty)
    }

    @Test("ワークスペース数が 0 以下なら何も割り当てない")
    func nonPositiveWorkspaceCount() {
        #expect(plan(["a.png"], workspaces: 0).isEmpty)
    }

    // MARK: - パス

    @Test("先頭の ~ を展開してから読む")
    func expandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var asked: [String] = []
        _ = WallpaperService.plan(
            directory: "~/Pictures/wallpapers", workspaceCount: 1,
            contents: { path in
                asked.append(path)
                return ["a.png"]
            })
        #expect(asked == ["\(home)/Pictures/wallpapers"])
    }

    @Test("末尾のスラッシュがあってもパスが壊れない")
    func trailingSlash() {
        let assigned = plan(["a.png"], workspaces: 1, directory: "/wall/")
        #expect(assigned[1] == "/wall/a.png")
    }

    // MARK: - 個別指定との併用

    /// ディレクトリで大枠を決めつつ、特定のワークスペースだけ差し替えられるようにする。
    @Test("個別指定はディレクトリより優先する")
    func explicitMapWins() {
        let merged = WallpaperService.merge(
            directory: ["1": "/wall/a.png", "2": "/wall/b.png"].reduce(
                into: [WorkspaceID: String]()
            ) { $0[Int($1.key)!] = $1.value },
            explicit: [2: "/special/x.png"])
        #expect(merged[1] == "/wall/a.png")
        #expect(merged[2] == "/special/x.png")
    }

    @Test("個別指定だけでも成り立つ")
    func explicitOnly() {
        let merged = WallpaperService.merge(directory: [:], explicit: [3: "/x.png"])
        #expect(merged == [3: "/x.png"])
    }

    // MARK: - 実ディレクトリでの往復

    @Test("実際のディレクトリを読んで割り当てる")
    func readsRealDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("comet-wallpaper-dir-test", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["2.png", "1.png", "notes.txt"] {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.appendingPathComponent(name))
        }

        let assigned = WallpaperService.plan(directory: directory.path, workspaceCount: 4)
        #expect(assigned.count == 4)
        #expect(assigned[1]?.hasSuffix("/1.png") == true)
        #expect(assigned[2]?.hasSuffix("/2.png") == true)
        #expect(assigned[3]?.hasSuffix("/1.png") == true, "足りないので繰り返す")
    }

    @Test("存在しないディレクトリでは何も割り当てない")
    func realMissingDirectory() {
        let assigned = WallpaperService.plan(
            directory: "/tmp/comet-no-such-directory-\(UUID().uuidString)", workspaceCount: 10)
        #expect(assigned.isEmpty)
    }
}
