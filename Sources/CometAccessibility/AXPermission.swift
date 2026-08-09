// kAXTrustedCheckOptionPrompt は C 側で可変グローバルとして宣言されているため、
// Swift 6 の並行性検査がそのままでは参照を許さない。実際には初期化後に書き換わらない
// 定数なので @preconcurrency で診断を落とす。
@preconcurrency import ApplicationServices
import Foundation

/// アクセシビリティ権限の確認。
///
/// この権限が無いと他プロセスのウィンドウは一切操作できないため、
/// 起動時に必ず確認する。
///
/// - Note: 権限はコード署名の同一性に紐づく。ad-hoc 署名だとビルドのたびに
///   ハッシュが変わって権限が外れるため、開発中は署名を固定すること
///   （`scripts/make-signing-cert.sh` 参照）。
public enum AXPermission {

    /// 権限があるか。ダイアログは出さない。
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 権限が無ければシステムのダイアログを表示する。
    ///
    /// - Returns: 呼び出し時点で権限があったかどうか。
    ///   ダイアログで許可しても即座に `true` にはならないので、
    ///   許可を待つ場合は ``isTrusted()`` をポーリングする。
    @discardableResult
    public static func promptIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 権限が付与されるまで待つ。
    ///
    /// - Parameters:
    ///   - timeout: 待つ上限（秒）。
    ///   - pollInterval: 確認間隔（秒）。
    ///   - onWait: 初回の待機開始時に一度だけ呼ばれる。案内表示用。
    /// - Returns: 権限を得られたか。
    public static func waitUntilTrusted(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 1.0,
        onWait: () -> Void = {}
    ) -> Bool {
        if isTrusted() { return true }

        promptIfNeeded()
        onWait()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
            if isTrusted() { return true }
        }
        return isTrusted()
    }
}
