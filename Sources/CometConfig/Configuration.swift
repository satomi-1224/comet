import CoreGraphics
import Foundation
import CometCore
import CometInput
import CometSupport

/// ホットキー1つ分の割り当て。
public struct Binding: Sendable, Equatable {
    /// 設定に書かれていた綴り。ログと重複検出に使う。
    public let spec: String
    public let hotkey: Hotkey
    /// 押されたときに順に実行するコマンド。**まとめて1回の再配置になる。**
    public let commands: [Command]

    public init(spec: String, hotkey: Hotkey, commands: [Command]) {
        self.spec = spec
        self.hotkey = hotkey
        self.commands = commands
    }
}

/// 読み込み中に見つかった問題。
///
/// **設定の誤りで起動を止めない。** 読めなかった項目は既定値に落として理由をここへ積み、
/// 利用者が原因を突き止められるようにする。ホットキーが1つ効かないだけで
/// ウィンドウマネージャが上がらないのは困る。
public struct Problem: Sendable, Equatable, CustomStringConvertible {

    public enum Kind: Sendable, Equatable {
        /// 綴りは知っているが、まだ実装していないコマンド。
        case unsupportedCommand
        /// キー指定を解釈できない。
        case invalidBinding
        /// コマンドを解釈できない。
        case invalidCommand
        /// 値が候補にない。
        case invalidValue
        /// ウィンドウルールとして成立していない。
        case invalidRule
        /// 設定ファイルそのものを読めない。
        case unreadable
        /// キーバインドが1つも無い。
        case noBindings
        /// 綴りは知っているが、まだ効かない設定項目。
        case unsupportedOption
        /// 知らない項目名。**綴り間違いはこれで気付く。**
        ///
        /// `Decodable` は知らないキーを黙って捨てるので、照合しないと
        /// 「設定したのに効かない」だけが残る。
        case unknownKey
    }

    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var description: String { detail }
}

/// 設定の全体。
public struct Configuration: Sendable, Equatable {

    /// 既定の間隔。アプリ間も画面の縁も 3pt で揃える。
    ///
    /// **アプリ間（inner）は枠線の幅より広くしておく**
    /// （枠線はウィンドウの外側へ幅ぶん広がるので、狭いと隣の中身に重なる）。
    public var gaps = Gaps(inner: 3, outer: 3)
    public var normalization = NormalizationConfig.default
    public var insertionStrategy = TreeSync.InsertionStrategy.split
    public var defaultOrientation = DefaultOrientation.auto
    /// ログイン時に自動起動するか。**アプリバンドルで動かしているときだけ効く。**
    public var startAtLogin = false
    public var workspaceCount = 10
    /// 非表示ワークスペースのウィンドウがアクティブになったらそちらへ移るか。
    public var focusFollowsActivation = true
    /// 表示中のワークスペースの番号をもう一度押したら直前へ戻るか
    ///（i3 の `workspace_auto_back_and_forth`）。
    public var workspaceAutoBackAndForth = false
    /// ワークスペース番号 → 名前。インジケータの表示にだけ使う。
    public var workspaceNames: [WorkspaceID: String] = [:]
    public var hiddenWindowStrategy = HiddenWindowStrategy.hideApp
    /// 設定に書かれていなければ `nil`。コマンドライン引数の指定を上書きしないため。
    public var logLevel: LogLevel?
    public var performance = PerformanceOptions()
    public var border = BorderStyle()
    public var indicator = IndicatorStyle.both
    public var hudDuration: TimeInterval = 0.4
    /// 並べる対象のディスプレイ。既定は全部（i3 と同じ）。
    public var monitorScope: MonitorScope = .all
    /// ワークスペース番号 → 壁紙のパス。**実在の検証は読み込み側で行う。**
    public var wallpapers: [WorkspaceID: String] = [:]
    /// 壁紙を入れたディレクトリ。名前順にワークスペースへ割り当てる。
    /// 個別指定（`wallpapers`）のほうが優先される。
    public var wallpaperDirectory: String?
    /// アプリ巡回で「続けて押している」とみなす時間。0 なら毎回組み直す。
    public var focusCycleReset: TimeInterval = 1.5
    /// 巡回の対象範囲。
    public var focusCycleScope: FocusCycleScope = .activeWorkspace
    /// ポインタが乗ったウィンドウへフォーカスを移すか（i3 の `focus_follows_mouse`）。
    ///
    /// **i3 の既定は有効だが、comet では無効を既定にしている。** macOS は
    /// クリックでフォーカスを移す前提で作られており、乗せただけで前面が変わると
    /// 「触っていないのにウィンドウが入れ替わる」と受け取られやすい。
    public var focusFollowsMouse = false
    /// 方向フォーカスが端で反対側へ回るか（i3 の `focus_wrapping`）。
    ///
    /// **i3 の既定は有効だが、comet では無効を既定にしている。**
    /// 回ると「右端で右を押したら左端へ飛ぶ」ことになり、行き先が読めない。
    public var focusWrapping = false
    /// モード名 → バインド。`main` が既定の層。
    ///
    /// **i3 の `mode "resize"` に相当する層。** 層の中では修飾キーなしのキーも奪う。
    public var modes: [String: [Binding]] = [:]

    /// 既定の層のバインド。
    public var bindings: [Binding] {
        get { modes[Configuration.mainMode] ?? [] }
        set { modes[Configuration.mainMode] = newValue }
    }

    /// 既定の層の名前。
    public static let mainMode = "main"
    public var windowRules: [WindowRule] = []
    public var problems: [Problem] = []

    public init() {}

    /// 組み込みの既定設定。
    ///
    /// **Swift の構造体ではなく TOML で持つ。** こうしておくと
    /// 「既定がそのまま設定ファイルの雛形になる」ことが構造的に保証され、
    /// 既定と書き方が食い違わない。`--print-default-config` でそのまま出せる。
    public static let defaultTOML = """
        # comet の設定
        #
        # 置き場所: ~/.config/comet/config.toml
        # この内容は `comet --print-default-config` で出力できる。
        #
        # 保存すると自動で読み直す（ツリーの形は保たれる）。

        # ログイン時に自動起動する。アプリバンドルで動かしているときだけ効く。
        start-at-login = false

        [normalization]
        # 子が1つだけのコンテナを潰し、その子を親へ昇格させる
        flatten-containers          = true
        # コンテナの子コンテナを親と逆の向きにする
        # （`layout` コマンドで手で選んだ向きは対象外）
        opposite-orientation-nested = true

        [layout]
        # ルートの分割方向: "auto" | "horizontal" | "vertical"
        # auto は領域が横長なら horizontal
        default-orientation = "auto"

        # 新しいウィンドウの入り方
        #   "split"   フォーカス中のウィンドウの領域を分割して入る（dwindle）
        #   "sibling" フォーカス中のウィンドウの隣に並べる（AeroSpace と同じ）
        insertion = "split"

        [focus]
        # アプリ巡回（focus next-app）で、続けて押したときに同じ並びを使い続ける時間。
        # これを過ぎると「最近使ったアプリ順」で組み直す。0 にすると毎回組み直す。
        cycle-reset-ms = 1500

        # 巡回の対象
        #   "workspace" 表示中のワークスペースのウィンドウだけ
        #   "all"       全ワークスペース（行き先のワークスペースへ自動で切り替わる）
        cycle-scope = "workspace"

        # ポインタが乗ったウィンドウへフォーカスを移す（i3 の focus_follows_mouse）。
        # i3 の既定は有効だが、macOS はクリックでフォーカスを移す前提なので
        # comet では無効を既定にしている。
        follows-mouse = false

        # 方向フォーカスが端で反対側へ回る（i3 の focus_wrapping）。
        # 2枚だけ並べているときに alt-h / alt-l で往復できる。
        # 既定は無効（回ると行き先が押す前に読めない）。
        wrapping = false

        [monitors]
        # 並べる対象のディスプレイ
        #   "all"  すべて並べる（i3 と同じ。既定）
        #   "main" メインディスプレイだけを並べ、他は素の macOS のまま使う
        manage = "all"

        [workspaces]
        count = 10

        # 非表示ワークスペースのウィンドウの隠し方
        #   "hide-app"   アプリごと非表示にする（Cmd+H 相当）。完全に消え、
        #                Mission Control にも出ない。ただし粒度がアプリ単位なので、
        #                表示中のワークスペースにもウィンドウを持つアプリは
        #                自動的に隅寄せへ落ちる
        #   "off-screen" 画面の隅へ追い込む。1pt × 46pt の角が残る
        #                （macOS はウィンドウを画面外へ出させない）
        hidden = "hide-app"

        # 非表示ワークスペースのウィンドウが Cmd+Tab などでアクティブになったら
        # そのワークスペースへ移る。切ると「アプリは前面だが見えない」状態になる。
        focus-follows-activation = true

        # 表示中の番号をもう一度押したら直前のワークスペースへ戻る
        # （i3 の workspace_auto_back_and_forth）。押し間違いの取り消しにもなる。
        auto-back-and-forth = false

        # ワークスペースの名前。メニューバーと HUD の表示にだけ使う
        # （番号は変わらない）。書いた番号だけに付く。
        [workspaces.names]
        # 1 = "web"
        # 2 = "code"

        [gaps]
        # アプリ間の間隔。**枠線の幅（[border] width）より広くしておく。**
        # 枠線はウィンドウの外側へ幅ぶん広がるので、狭いと隣の中身に重なる。
        inner-horizontal = 3
        inner-vertical   = 3
        # 画面の縁との間隔
        outer-top        = 3
        outer-bottom     = 3
        outer-left       = 3
        outer-right      = 3

        [performance]
        ax-timeout-ms          = 100
        apply-interval-ms      = 8
        max-correction-retries = 3

        # ホットキーを押しっぱなしにしたときの繰り返し（resize だけが対象）。
        # Carbon のホットキーはキー連射では繰り返し発火しないので comet 側で繰り返す。
        repeat-delay-ms        = 250
        repeat-interval-ms     = 30

        # ウィンドウ操作を遅くする AXEnhancedUserInterface を無効化する。
        # VoiceOver を併用するなら false にする。
        disable-enhanced-ui = true

        [debug]
        # "trace" | "debug" | "info" | "warn" | "error" | "off"
        log-level = "info"

        # 適用のレイテンシをアプリ別に集計する。ctrl-alt-shift-t で出力。
        timing = false

        # ---- キーバインド ----
        #
        # コマンドの綴りは AeroSpace 互換で、i3 の綴りも受ける
        # （`kill` / `reload` / `split h` / `fullscreen toggle` /
        #  `floating toggle` / `resize grow width 50 px` /
        #  `move container to workspace 3` / `move workspace to output right` など）。
        #
        # 綴りは知っているが comet に無いコマンド（macos-native-fullscreen など）は
        # 飛ばされ、起動時のログに「未対応」として残る。綴り間違いは1件ずつ警告に出る。

        [mode.main.binding]
        # -- フォーカス移動 --
        alt-h = "focus left"
        alt-j = "focus down"
        alt-k = "focus up"
        alt-l = "focus right"

        # -- アプリ・ウィンドウの巡回 --
        # 押し続けている間は並びを組み直さない（[focus] cycle-reset-ms）。
        # 逆順は prev-app / prev-window-in-app。
        alt-f = "focus next-app"
        alt-d = "focus next-window-in-app"

        # -- ウィンドウ移動 --
        alt-shift-h = "move left"
        alt-shift-j = "move down"
        alt-shift-k = "move up"
        alt-shift-l = "move right"

        # -- リサイズ --
        alt-ctrl-h = "resize width -50"
        alt-ctrl-j = "resize height +50"
        alt-ctrl-k = "resize height -50"
        alt-ctrl-l = "resize width +50"

        # -- まとめる --
        alt-e = "join-with right"
        alt-w = "join-with down"

        # -- 次のウィンドウの入り方（i3 の split h / split v） --
        # その場では何も起きない。次に開いた1枚がこの向きに入る。
        alt-b = "split horizontal"
        alt-v = "split vertical"

        # -- コンテナを選ぶ（i3 の focus parent / focus child） --
        # 上げると入れ子ごと move / resize / layout の対象になる。枠線が範囲を示す。
        alt-a       = "focus parent"
        alt-shift-a = "focus child"

        # -- タイルとフローティングの間でフォーカスを往復（i3 の focus mode_toggle） --
        alt-space = "focus mode-toggle"

        # -- レイアウト切替 --
        alt-slash   = "layout tiles horizontal vertical"
        alt-shift-f = "layout floating tiling"
        # 入れ子を全部ほどいてルート直下に並べ直す（収拾がつかなくなったとき）
        alt-shift-slash = "flatten-workspace-tree"

        # -- アプリを起動する（i3 の $mod+Return） --
        # exec は残りを1行そのままシェルへ渡す。空白も引用符も書いたまま。
        # launchd から起動した場合 PATH は最小限なので、絶対パスか open -a を使う。
        alt-enter = "exec open -a Terminal"

        # -- モニタ間の移動（i3 の output。2台以上のときだけ効く） --
        alt-s       = "focus-monitor next"
        alt-shift-s = "move-node-to-monitor next"
        alt-ctrl-s  = "move-workspace-to-monitor next"

        # -- ワークスペース --
        alt-tab    = "workspace back-and-forth"
        # 番号順に送る。端では巻き戻る。
        alt-period = "workspace next"
        alt-comma  = "workspace prev"
        alt-1 = "workspace 1"
        alt-2 = "workspace 2"
        alt-3 = "workspace 3"
        alt-4 = "workspace 4"
        alt-5 = "workspace 5"
        alt-6 = "workspace 6"
        alt-7 = "workspace 7"
        alt-8 = "workspace 8"
        alt-9 = "workspace 9"
        alt-0 = "workspace 10"

        alt-shift-1 = ["move-node-to-workspace 1", "workspace 1"]
        alt-shift-2 = ["move-node-to-workspace 2", "workspace 2"]
        alt-shift-3 = ["move-node-to-workspace 3", "workspace 3"]
        alt-shift-4 = ["move-node-to-workspace 4", "workspace 4"]
        alt-shift-5 = ["move-node-to-workspace 5", "workspace 5"]
        alt-shift-6 = ["move-node-to-workspace 6", "workspace 6"]
        alt-shift-7 = ["move-node-to-workspace 7", "workspace 7"]
        alt-shift-8 = ["move-node-to-workspace 8", "workspace 8"]
        alt-shift-9 = ["move-node-to-workspace 9", "workspace 9"]
        alt-shift-0 = ["move-node-to-workspace 10", "workspace 10"]

        # -- 全画面（1枚を領域いっぱいに広げる。トグル） --
        alt-semicolon = "fullscreen"

        # -- 分割の比率を均等に戻す --
        alt-shift-e = "balance-sizes"

        # -- フローティングのウィンドウを中央へ（i3 の move position center） --
        # フローティング中は alt-shift-hjkl が「点数で動かす」に変わる。
        alt-c = "move position center"

        # -- ウィンドウを閉じる --
        alt-shift-q = "close-window"

        # -- リサイズモードへ入る（i3 の mode "resize"） --
        alt-r = "mode resize"

        # ---- キーの層（i3 の mode） ----
        #
        # **層の中では修飾キーなしのキーも奪う。** それが層の目的で、
        # `h` だけで境界を動かせるようになる。
        # 抜けるキーを書き忘れても `esc` では戻れるようにしてある。
        [mode.resize.binding]
        h = "resize width -50"
        j = "resize height +50"
        k = "resize height -50"
        l = "resize width +50"
        # 大きく動かす
        shift-h = "resize width -150"
        shift-j = "resize height +150"
        shift-k = "resize height -150"
        shift-l = "resize width +150"
        esc   = "mode main"
        enter = "mode main"

        # ---- ウィンドウルール ----
        #
        # 初めて見るウィンドウにだけ当たる（手で戻した選択を上書きしない）。
        #
        # if-app-id                 バンドル ID の完全一致
        # if-window-title-substring タイトルの部分一致
        # if-window-title-regex     タイトルの正規表現（部分一致）
        # run                       "layout floating" … 並べずに浮かせる
        #                           "move-node-to-workspace <番号>" … 置き場所を固定する
        #                           （i3 の assign）

        [[window-rule]]
        if-app-id = "com.apple.systempreferences"
        run       = "layout floating"

        # 置き場所を固定する例（i3 の assign）。
        # [[window-rule]]
        # if-app-id = "com.tinyspeck.slackmacgap"
        # run       = "move-node-to-workspace 9"

        # ---- 見た目 ----

        [border]
        enabled       = true
        width         = 2.0
        radius        = 10.0
        color-focused = "#7aa2f7"
        # フォーカスしていないタイルにも枠を描く（i3 と同じ見え方）。
        # 書かなければフォーカス中の1枚だけに枠が出る。
        # color-unfocused = "#3b4261"

        [indicator]
        # "menubar" | "hud" | "both" | "off"
        style           = "both"
        hud-duration-ms = 400

        [wallpaper]
        enabled = true

        # 壁紙を入れたディレクトリ。**これだけ書けば済む。**
        # 名前順（Finder と同じ並び）にワークスペース数まで取り、
        # 足りなければ先頭から繰り返す（3枚なら 1231231231）。
        #
        # **ディレクトリが無い / 画像が1枚も無いときは壁紙を変えない**ので、
        # 既定で書いてあっても画像を置くまで何も起きない。
        dir = "~/Pictures/wallpapers"

        # ワークスペース番号 → 画像パス。dir より優先する。
        # 未設定のワークスペースでは壁紙を変えない。
        # 存在しないパスは起動時に警告して捨てる。
        [wallpaper.map]
        # 1 = "~/Pictures/wallpapers/wallpaper1.jpg"
        # 2 = "~/Pictures/wallpapers/wallpaper2.jpg"
        """
}
