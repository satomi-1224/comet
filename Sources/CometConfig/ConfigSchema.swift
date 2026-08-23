import Foundation
import TOMLDecoder

/// 設定に書ける項目の一覧と、書かれた項目の照合。
///
/// ## なぜ要るのか
///
/// `Decodable` は**知らないキーを黙って捨てる**。`[gaps] inner = 5`（正しくは
/// `inner-horizontal`）と書いても、TOML としては正しいので読み込みは成功し、
/// 値だけが効かない。利用者から見れば「設定したのに変わらない」だけで、
/// 打ち間違いなのか未対応なのかも分からない。
///
/// 設定の誤りは**必ず理由付きで伝える**という方針（``Problem``）を、
/// 項目名の綴りにも広げるための照合表。
enum ConfigSchema {

    /// ある位置に書ける子の形。
    indirect enum Node: Sendable {
        /// 値（これ以上の入れ子は無い）。
        case value
        /// 決まった名前の子だけを取る表。
        case table([String: Node])
        /// 名前が自由な子を取る表。キーバインドの綴りやワークスペース番号がここ。
        case free(Node)
    }

    /// 設定ファイル全体の形。**新しい項目を足したらここにも足すこと。**
    /// 足し忘れると「知らない項目」として警告が出るので、テストで気付ける。
    static let root: Node = .table([
        "start-at-login": .value,
        "normalization": .table([
            "flatten-containers": .value,
            "opposite-orientation-nested": .value,
        ]),
        "layout": .table([
            "default-orientation": .value,
            "insertion": .value,
        ]),
        "workspaces": .table([
            "count": .value,
            "hidden": .value,
            "focus-follows-activation": .value,
            "auto-back-and-forth": .value,
            "names": .free(.value),
        ]),
        "monitors": .table(["manage": .value]),
        "gaps": .table([
            "inner-horizontal": .value,
            "inner-vertical": .value,
            "outer-top": .value,
            "outer-bottom": .value,
            "outer-left": .value,
            "outer-right": .value,
        ]),
        "performance": .table([
            "ax-timeout-ms": .value,
            "apply-interval-ms": .value,
            "max-correction-retries": .value,
            "repeat-delay-ms": .value,
            "repeat-interval-ms": .value,
            "disable-enhanced-ui": .value,
        ]),
        "debug": .table([
            "log-level": .value,
            "timing": .value,
        ]),
        "border": .table([
            "enabled": .value,
            "width": .value,
            "radius": .value,
            "color-focused": .value,
            "color-unfocused": .value,
        ]),
        "indicator": .table([
            "style": .value,
            "hud-duration-ms": .value,
        ]),
        "wallpaper": .table([
            "enabled": .value,
            "dir": .value,
            "map": .free(.value),
        ]),
        "focus": .table([
            "cycle-reset-ms": .value,
            "cycle-scope": .value,
            "follows-mouse": .value,
            "wrapping": .value,
        ]),
        // mode.<名前>.binding.<キーの綴り>
        "mode": .free(.table(["binding": .free(.value)])),
        "window-rule": .table([
            "if-app-id": .value,
            "if-window-title-substring": .value,
            "if-window-title-regex": .value,
            "run": .value,
        ]),
    ])

    /// 書かれた項目を照合し、知らないものを問題として返す。
    ///
    /// TOML そのものが読めない場合は空を返す（本体の読み込みが同じ誤りを報告する）。
    static func unknownKeys(in toml: String) -> [Problem] {
        guard let tree = try? TOMLDecoder().decode(KeyTree.self, from: toml) else { return [] }
        var problems: [Problem] = []
        walk(tree, against: root, path: [], into: &problems)
        return problems
    }

    private static func walk(
        _ tree: KeyTree, against node: Node, path: [String], into problems: inout [Problem]
    ) {
        switch node {
        case .value:
            // 値のはずの場所に表が来ている。名前は合っているので綴りの問題ではない。
            for name in tree.children.keys.sorted() {
                problems.append(
                    Problem(
                        kind: .unknownKey,
                        detail: "\(describe(path + [name])) は設定に無い項目"))
            }
        case .free(let child):
            for name in tree.children.keys.sorted() {
                walk(tree.children[name]!, against: child, path: path + [name], into: &problems)
            }
        case .table(let allowed):
            for name in tree.children.keys.sorted() {
                guard let child = allowed[name] else {
                    problems.append(
                        Problem(
                            kind: .unknownKey,
                            detail: "\(describe(path + [name])) は設定に無い項目"
                                + suggestion(for: name, among: allowed.keys)))
                    continue
                }
                walk(tree.children[name]!, against: child, path: path + [name], into: &problems)
            }
        }
    }

    /// 打ち間違いに見えるものは候補を添える。**候補が無ければ何も言わない**
    ///（見当違いの提案は混乱させるだけ）。
    private static func suggestion(for name: String, among candidates: some Collection<String>)
        -> String
    {
        let close = candidates
            .map { (name: $0, distance: editDistance($0, name)) }
            .filter { $0.distance <= max(1, min(3, name.count / 3)) }
            .sorted { $0.distance < $1.distance }
        guard let best = close.first else { return "" }
        return "（\(best.name) の綴り間違い？）"
    }

    private static func describe(_ path: [String]) -> String {
        guard path.count > 1 else { return path.joined() }
        return "[\(path.dropLast().joined(separator: "."))] \(path[path.count - 1])"
    }

    /// レーベンシュタイン距離。候補を出すためだけなので素朴な実装で足りる。
    static func editDistance(_ a: String, _ b: String) -> Int {
        let first = Array(a)
        let second = Array(b)
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }
        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)
        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let cost = first[i - 1] == second[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[second.count]
    }
}

/// TOML を「キーの木」として読むためだけの型。**値には興味が無い。**
///
/// 配列（`[[window-rule]]`）は要素のキーをまとめて1つの表として見る。
/// 何番目の要素にどのキーがあったかまでは要らない（綴りの照合が目的）。
///
/// - Important: **入れ子は `nestedContainer` で降りること。**
///   `container.decode(KeyTree.self, forKey:)` で降りてはいけない。TOMLDecoder は
///   値（表でも配列でもないもの）に対して**同じ `Decoder` を使い回す**ため、
///   その中で `container(keyedBy:)` を呼ぶと**親の表がもう一度返る**。
///   `init(from:)` から再帰すると同じ表を無限に降り続けてスタックを溢れさせる
///   （実際に落ちた）。`nestedContainer` は表のときだけ成功するので区別できる。
struct KeyTree: Decodable {

    var children: [String: KeyTree] = [:]

    init() {}

    /// **根でだけ呼ばれる。** 入れ子は ``children(of:)`` が組み立てる。
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyKey.self) else { return }
        children = Self.children(of: container)
    }

    private static func children(of container: KeyedDecodingContainer<AnyKey>)
        -> [String: KeyTree]
    {
        var result: [String: KeyTree] = [:]
        for key in container.allKeys {
            result[key.stringValue] = child(of: container, forKey: key)
        }
        return result
    }

    private static func child(of container: KeyedDecodingContainer<AnyKey>, forKey key: AnyKey)
        -> KeyTree
    {
        var tree = KeyTree()
        if let nested = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) {
            tree.children = children(of: nested)
            return tree
        }
        guard var array = try? container.nestedUnkeyedContainer(forKey: key) else {
            return tree  // 値。子は無い。
        }
        // `[[window-rule]]` のような表の配列。要素のキーをまとめて見る。
        //
        // **失敗したら必ず抜ける。** `nestedContainer` は表でない要素では
        // 添字を進めずに投げるので、続けると回り続ける。
        while !array.isAtEnd {
            guard let nested = try? array.nestedContainer(keyedBy: AnyKey.self) else { break }
            tree.children.merge(children(of: nested)) { existing, _ in existing }
        }
        return tree
    }

    /// 任意の名前を受けるキー。
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
