import CoreGraphics
import Testing

@testable import CometCore

/// どのウィンドウをタイル管理下に置くかの判定。
///
/// 誤って管理下に入れると、ダイアログやポップオーバーが勝手にリサイズされて
/// アプリが壊れて見える。逆に落としすぎると普通のウィンドウが並ばない。
@Suite("WindowClassifier")
struct WindowClassifierTests {

    private func snapshot(
        role: String? = AXRole.window,
        subrole: String? = AXSubrole.standardWindow,
        isFullScreen: Bool = false,
        isMinimized: Bool = false,
        size: CGSize = CGSize(width: 800, height: 600)
    ) -> WindowSnapshot {
        WindowSnapshot(
            role: role, subrole: subrole,
            isFullScreen: isFullScreen, isMinimized: isMinimized, size: size)
    }

    @Test("標準ウィンドウはタイル対象")
    func standardWindowIsTiled() {
        #expect(WindowClassifier.classify(snapshot()) == .tiled)
    }

    // MARK: - 除外条件

    @Test("role が取れないものは除外")
    func missingRoleIsUnmanaged() {
        #expect(WindowClassifier.classify(snapshot(role: nil)) == .unmanaged(.unknownRole))
    }

    @Test("AXWindow 以外は除外")
    func nonWindowRoleIsUnmanaged() {
        #expect(WindowClassifier.classify(snapshot(role: "AXSheet")) == .unmanaged(.notAWindow))
    }

    @Test(
        "標準以外の subrole は除外",
        arguments: [
            AXSubrole.dialog,
            AXSubrole.systemDialog,
            AXSubrole.floatingWindow,
            AXSubrole.systemFloatingWindow,
            "AXUnknown",
        ])
    func nonStandardSubroleIsUnmanaged(subrole: String) {
        #expect(
            WindowClassifier.classify(snapshot(subrole: subrole))
                == .unmanaged(.nonStandardSubrole))
    }

    // subrole を返さないウィンドウは素性が分からない。誤ってダイアログを掴むより
    // 落とす方が害が小さいので除外する。実際に落ちたらログで気づけるようにする。
    @Test("subrole が取れないものは除外")
    func missingSubroleIsUnmanaged() {
        #expect(
            WindowClassifier.classify(snapshot(subrole: nil)) == .unmanaged(.nonStandardSubrole))
    }

    // ネイティブフルスクリーンは独自の Space を作るため、画面外退避方式と根本的に衝突する。
    @Test("ネイティブフルスクリーンは除外")
    func fullScreenIsUnmanaged() {
        #expect(WindowClassifier.classify(snapshot(isFullScreen: true)) == .unmanaged(.fullScreen))
    }

    @Test("最小化中は除外")
    func minimizedIsUnmanaged() {
        #expect(WindowClassifier.classify(snapshot(isMinimized: true)) == .unmanaged(.minimized))
    }

    @Test("極端に小さいウィンドウは除外")
    func tinyWindowIsUnmanaged() {
        let tiny = CGSize(width: 20, height: 20)
        #expect(WindowClassifier.classify(snapshot(size: tiny)) == .unmanaged(.tooSmall))
    }

    @Test("幅か高さの片方だけ小さくても除外")
    func narrowWindowIsUnmanaged() {
        #expect(
            WindowClassifier.classify(snapshot(size: CGSize(width: 20, height: 600)))
                == .unmanaged(.tooSmall))
        #expect(
            WindowClassifier.classify(snapshot(size: CGSize(width: 800, height: 20)))
                == .unmanaged(.tooSmall))
    }

    @Test("最小サイズちょうどは通す")
    func minimumSizeIsInclusive() {
        let minimum = WindowClassifier.minimumSize
        #expect(WindowClassifier.classify(snapshot(size: minimum)) == .tiled)
    }

    @Test("最小サイズは差し替えできる")
    func minimumSizeIsConfigurable() {
        let size = CGSize(width: 100, height: 100)
        #expect(
            WindowClassifier.classify(snapshot(size: size), minimumSize: CGSize(width: 200, height: 200))
                == .unmanaged(.tooSmall))
        #expect(
            WindowClassifier.classify(snapshot(size: size), minimumSize: CGSize(width: 50, height: 50))
                == .tiled)
    }

    // MARK: - 判定の優先順位

    // 診断の質に効く。ダイアログが最小化されているとき「最小化」と報告すると
    // 復帰時にタイル対象になると誤解する。素性の問題を先に報告する。
    @Test("素性の問題は一時的な状態より優先して報告される")
    func permanentReasonsTakePrecedence() {
        #expect(
            WindowClassifier.classify(snapshot(role: "AXSheet", isMinimized: true))
                == .unmanaged(.notAWindow))
        #expect(
            WindowClassifier.classify(snapshot(subrole: AXSubrole.dialog, isMinimized: true))
                == .unmanaged(.nonStandardSubrole))
    }

    @Test("フルスクリーンは最小化より優先")
    func fullScreenBeforeMinimized() {
        #expect(
            WindowClassifier.classify(snapshot(isFullScreen: true, isMinimized: true))
                == .unmanaged(.fullScreen))
    }

    // MARK: - 再評価の要否

    // 一時的な理由なら状態が変わったときに再評価すればよい。
    // 恒久的な理由なら判定をキャッシュしてよく、毎回 AX を叩かなくて済む。
    @Test("最小化とフルスクリーンは一時的、素性の問題は恒久的")
    func transienceIsDistinguished() {
        #expect(UnmanagedReason.minimized.isTransient)
        #expect(UnmanagedReason.fullScreen.isTransient)
        #expect(UnmanagedReason.tooSmall.isTransient, "リサイズで解消しうる")

        #expect(!UnmanagedReason.unknownRole.isTransient)
        #expect(!UnmanagedReason.notAWindow.isTransient)
        #expect(!UnmanagedReason.nonStandardSubrole.isTransient)
    }

    @Test("除外理由は説明文を持つ")
    func reasonsAreDescribable() {
        for reason in UnmanagedReason.allCases {
            #expect(!reason.description.isEmpty)
        }
    }

    @Test("disposition から管理下かどうかを判定できる")
    func dispositionExposesManagedFlag() {
        #expect(WindowDisposition.tiled.isTiled)
        #expect(!WindowDisposition.unmanaged(.minimized).isTiled)
    }

    // MARK: - フォーカスを追う対象か

    /// **Chrome の拡張機能のポップアップに枠線が吸われた**ことで見つかった。
    ///
    /// タイル対象から外していても台帳には載るため、フォーカス追跡だけがそちらへ移り、
    /// 枠線がポップアップを囲み、以降のコマンドの起点もそこになっていた。
    /// 「置き場所を決めているウィンドウ」だけを追う。
    @Test("管理していないウィンドウへはフォーカスを移さない")
    func focusTrackingSkipsUnmanagedWindows() {
        #expect(WindowDisposition.tiled.acceptsFocusTracking)
        #expect(WindowDisposition.floating.acceptsFocusTracking)
        // サブディスプレイのウィンドウは実在のアプリのウィンドウなので追う。
        #expect(WindowDisposition.unmanaged(.otherMonitor).acceptsFocusTracking)
        // ダイアログ・ポップオーバー・拡張機能のパネルは追わない。
        #expect(!WindowDisposition.unmanaged(.nonStandardSubrole).acceptsFocusTracking)
        #expect(!WindowDisposition.unmanaged(.notAWindow).acceptsFocusTracking)
        #expect(!WindowDisposition.unmanaged(.unknownRole).acceptsFocusTracking)
        #expect(!WindowDisposition.unmanaged(.tooSmall).acceptsFocusTracking)
        #expect(!WindowDisposition.unmanaged(.minimized).acceptsFocusTracking)
        #expect(!WindowDisposition.unmanaged(.fullScreen).acceptsFocusTracking)
    }

    // MARK: - 常に手前へ出る窓

    /// **YouTube などのピクチャーインピクチャが並べる対象に入っていた**ことで見つかった。
    ///
    /// AX 上はふつうのウィンドウとして見える（実測: `role=AXWindow`
    /// `subrole=AXStandardWindow` `title="ピクチャー イン ピクチャー"` 571x321）。
    /// role でも subrole でも大きさでも落とせない。`kCGWindowLayer` が
    /// 通常のウィンドウ 0 に対して 3 であることだけが手がかりになる。
    @Test("常に手前へ出る窓は並べる対象にしない")
    func alwaysOnTopWindowIsUnmanaged() {
        let pictureInPicture = WindowSnapshot(
            role: AXRole.window, subrole: AXSubrole.standardWindow,
            size: CGSize(width: 571, height: 321), layer: 3)
        #expect(WindowClassifier.classify(pictureInPicture) == .unmanaged(.alwaysOnTop))
        // フォーカスの巡回先にも枠線の対象にもしない。
        #expect(!WindowDisposition.unmanaged(.alwaysOnTop).acceptsFocusTracking)
        #expect(!WindowDisposition.unmanaged(.alwaysOnTop).showsFocusBorder)
        // 階層は状態ではなく素性なので、通知を待って評価し直す必要がない。
        #expect(!UnmanagedReason.alwaysOnTop.isTransient)
    }

    @Test("通常の階層のウィンドウはこれまでどおり並べる")
    func normalLayerStaysTiled() {
        let normal = WindowSnapshot(
            role: AXRole.window, subrole: AXSubrole.standardWindow,
            size: CGSize(width: 800, height: 600), layer: 0)
        #expect(WindowClassifier.classify(normal) == .tiled)
    }

    /// **取得に失敗しただけで全ウィンドウが管理外になってはいけない。**
    @Test("階層が分からないときは管理する")
    func unknownLayerStaysTiled() {
        let unknown = WindowSnapshot(
            role: AXRole.window, subrole: AXSubrole.standardWindow,
            size: CGSize(width: 800, height: 600), layer: nil)
        #expect(WindowClassifier.classify(unknown) == .tiled)
    }

    // MARK: - 枠線を描く対象か

    /// **ネイティブ全画面や最小化のあとも枠線が残った**ことで見つかった。
    ///
    /// フォーカスを追うかどうかとは別の判断になる。サブディスプレイのウィンドウは
    /// 追うが描かない（素の macOS のまま使う場所）。全画面・最小化は macOS 側が
    /// 見た目を持っていくので、こちらが枠を重ねると見えないものを囲むことになる。
    @Test("見えていないウィンドウには枠線を描かない")
    func borderOnlyForVisibleWindows() {
        #expect(WindowDisposition.tiled.showsFocusBorder)
        #expect(WindowDisposition.floating.showsFocusBorder)
        // 追跡はするが描かない、が両立する唯一の状態。
        #expect(WindowDisposition.unmanaged(.otherMonitor).acceptsFocusTracking)
        #expect(!WindowDisposition.unmanaged(.otherMonitor).showsFocusBorder)
        #expect(!WindowDisposition.unmanaged(.fullScreen).showsFocusBorder)
        #expect(!WindowDisposition.unmanaged(.minimized).showsFocusBorder)
        #expect(!WindowDisposition.unmanaged(.tooSmall).showsFocusBorder)
        #expect(!WindowDisposition.unmanaged(.nonStandardSubrole).showsFocusBorder)
        #expect(!WindowDisposition.unmanaged(.notAWindow).showsFocusBorder)
        #expect(!WindowDisposition.unmanaged(.unknownRole).showsFocusBorder)
    }
}
