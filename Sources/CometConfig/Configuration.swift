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
        /// まだ実装していないモード。
        case unsupportedMode
        /// 設定ファイルそのものを読めない。
        case unreadable
        /// キーバインドが1つも無い。
        case noBindings
        /// 綴りは知っているが、まだ効かない設定項目。
        case unsupportedOption
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

    public var gaps = Gaps(inner: 5, outer: 5)
    public var normalization = NormalizationConfig.default
    public var insertionStrategy = TreeSync.InsertionStrategy.split
    public var defaultOrientation = DefaultOrientation.auto
    public var workspaceCount = 10
    /// 非表示ワークスペースのウィンドウがアクティブになったらそちらへ移るか。
    public var focusFollowsActivation = true
    /// 設定に書かれていなければ `nil`。コマンドライン引数の指定を上書きしないため。
    public var logLevel: LogLevel?
    public var performance = PerformanceOptions()
    public var border = BorderStyle()
    public var indicator = IndicatorStyle.both
    public var hudDuration: TimeInterval = 0.4
    /// ワークスペース番号 → 壁紙のパス。**実在の検証は読み込み側で行う。**
    public var wallpapers: [WorkspaceID: String] = [:]
    public var bindings: [Binding] = []
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

        [workspaces]
        count = 10

        # 非表示ワークスペースのウィンドウが Cmd+Tab などでアクティブになったら
        # そのワークスペースへ移る。切ると「アプリは前面だが見えない」状態になる。
        focus-follows-activation = true

        [gaps]
        inner-horizontal = 5
        inner-vertical   = 5
        outer-top        = 5
        outer-bottom     = 5
        outer-left       = 5
        outer-right      = 5

        [performance]
        ax-timeout-ms          = 100
        apply-interval-ms      = 8
        max-correction-retries = 3

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
        # 未対応のコマンド（fullscreen / move-node-to-monitor）は書いてあっても飛ばされ、
        # 起動時のログに「未対応」として残る。

        [mode.main.binding]
        # -- フォーカス移動 --
        alt-h = "focus left"
        alt-j = "focus down"
        alt-k = "focus up"
        alt-l = "focus right"

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

        # -- レイアウト切替 --
        alt-slash   = "layout tiles horizontal vertical"
        alt-shift-f = "layout floating tiling"

        # -- ワークスペース --
        alt-tab = "workspace back-and-forth"
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

        # -- その他（未対応: Phase 4 以降） --
        alt-semicolon = "fullscreen"
        alt-s         = "move-node-to-monitor next"
        alt-a         = "move-node-to-monitor main"

        # ---- ウィンドウルール ----
        #
        # if-app-id                 バンドル ID の完全一致
        # if-window-title-substring タイトルの部分一致（正規表現ではない）
        # run                       今は "layout floating" のみ

        [[window-rule]]
        if-app-id = "com.apple.systempreferences"
        run       = "layout floating"

        # ---- 見た目 ----

        [border]
        enabled       = true
        width         = 2.0
        radius        = 10.0
        color-focused = "#7aa2f7"
        # タイル全部に枠を描く color-unfocused は未対応

        [indicator]
        # "menubar" | "hud" | "both" | "off"
        style           = "both"
        hud-duration-ms = 400

        [wallpaper]
        enabled = true

        # ワークスペース番号 → 画像パス。未設定のワークスペースでは壁紙を変えない。
        # 存在しないパスは起動時に警告して捨てる。
        [wallpaper.map]
        # 1 = "~/Pictures/wallpapers/wallpaper1.jpg"
        # 2 = "~/Pictures/wallpapers/wallpaper2.jpg"
        """
}
