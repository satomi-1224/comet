import AppKit
import CoreGraphics

/// レイアウトを文字グリッドに落として確認するための道具。
///
/// ウィンドウに触れずに配置を検証できるので、他のウィンドウマネージャが
/// 動いている環境でも安全に使える。
public enum LayoutPreview {

    /// 指定枚数を順に開いたときの配置を図示する。
    ///
    /// 「常に新しいウィンドウにフォーカスがある」状態を想定して積み上げるので、
    /// 実際に `count` 枚開いたときの形と一致する。
    public static func render(
        count: Int,
        area: CGRect,
        gaps: Gaps,
        strategy: TreeSync.InsertionStrategy = .split,
        columns: Int = 74,
        rows: Int = 22
    ) -> String {
        guard count > 0 else { return "（配置できるウィンドウがない）" }

        let root = ContainerNode(orientation: .automatic(for: area.size))
        var tiled: [CGWindowID] = []
        for id in 1...count {
            tiled.append(CGWindowID(id))
            TreeSync.reconcile(
                root: root, tiled: tiled, focused: CGWindowID(id - 1), strategy: strategy)
        }

        let layout = LayoutEngine.compute(root: root, area: area, gaps: gaps, scale: 1)
        let rects = layout.order.compactMap { layout.frames[$0] }
        guard !rects.isEmpty else { return "（配置できるウィンドウがない）" }

        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var grid = Array(
            repeating: Array(repeating: Character("·"), count: columns), count: rows)

        for (index, rect) in rects.enumerated() {
            let mark = index < letters.count ? letters[index] : "?"
            let x0 = scaled(rect.minX - area.minX, of: area.width, to: columns)
            let x1 = scaled(rect.maxX - area.minX, of: area.width, to: columns)
            let y0 = scaled(rect.minY - area.minY, of: area.height, to: rows)
            let y1 = scaled(rect.maxY - area.minY, of: area.height, to: rows)
            for y in y0..<max(y1, y0 + 1) where y < rows {
                for x in x0..<max(x1, x0 + 1) where x < columns {
                    grid[y][x] = mark
                }
            }
        }

        var lines: [String] = []
        lines.append("┌" + String(repeating: "─", count: columns) + "┐")
        for row in grid { lines.append("│" + String(row) + "│") }
        lines.append("└" + String(repeating: "─", count: columns) + "┘")
        for (index, rect) in rects.enumerated() {
            let mark = index < letters.count ? String(letters[index]) : "?"
            lines.append(
                "  \(mark)  (\(Int(rect.minX)), \(Int(rect.minY)))"
                    + "  \(Int(rect.width)) x \(Int(rect.height))")
        }
        lines.append("")
        lines.append("  ツリー: \(root)")
        return lines.joined(separator: "\n")
    }

    /// プライマリディスプレイの作業領域（AX 座標系）。取得できなければ代表値。
    @MainActor
    public static func primaryVisibleFrame() -> CGRect {
        guard let screen = NSScreen.screens.first else {
            return CGRect(x: 0, y: 0, width: 2560, height: 1600)
        }
        return Geometry.toAX(screen.visibleFrame, primaryMaxY: screen.frame.maxY)
    }

    private static func scaled(_ value: CGFloat, of total: CGFloat, to steps: Int) -> Int {
        guard total > 0 else { return 0 }
        return min(max(Int((value / total) * CGFloat(steps)), 0), steps)
    }
}
