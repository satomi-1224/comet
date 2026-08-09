import Testing

@testable import CometSupport

@Suite("LogLevel")
struct LogLevelTests {

    @Test("順序は trace < debug < info < warn < error < off")
    func ordering() {
        #expect(LogLevel.trace < LogLevel.debug)
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warn)
        #expect(LogLevel.warn < LogLevel.error)
        #expect(LogLevel.error < LogLevel.off)
    }

    @Test("name は往復する", arguments: LogLevel.allCases)
    func nameRoundTrip(level: LogLevel) {
        #expect(LogLevel(name: level.name) == level)
    }

    @Test("名前のパースは大文字小文字と前後空白を無視する")
    func nameParsingIsLenient() {
        #expect(LogLevel(name: "INFO") == .info)
        #expect(LogLevel(name: "  Debug  ") == .debug)
        #expect(LogLevel(name: "\tWARN\n") == .warn)
    }

    @Test("warning は warn の別名")
    func warnAlias() {
        #expect(LogLevel(name: "warning") == .warn)
    }

    @Test("未知の名前は nil")
    func unknownName() {
        #expect(LogLevel(name: "verbose") == nil)
        #expect(LogLevel(name: "") == nil)
        #expect(LogLevel(name: "   ") == nil)
    }

    // isEnabled は「あるレベルのメッセージを、あるしきい値の下で出力すべきか」を返す。
    // ホットパスで毎回評価されるため純粋関数として切り出してある。

    @Test("しきい値以上のレベルは出力される")
    func atOrAboveThreshold() {
        #expect(LogLevel.isEnabled(.info, threshold: .info))
        #expect(LogLevel.isEnabled(.warn, threshold: .info))
        #expect(LogLevel.isEnabled(.error, threshold: .trace))
    }

    @Test("しきい値未満のレベルは抑制される")
    func belowThreshold() {
        #expect(!LogLevel.isEnabled(.trace, threshold: .info))
        #expect(!LogLevel.isEnabled(.debug, threshold: .info))
        #expect(!LogLevel.isEnabled(.info, threshold: .error))
    }

    @Test("しきい値 off は全てを抑制する")
    func thresholdOffSuppressesEverything() {
        for level in LogLevel.allCases {
            #expect(!LogLevel.isEnabled(level, threshold: .off))
        }
    }

    @Test("off はメッセージのレベルとしては常に無効")
    func offIsNotAMessageLevel() {
        for threshold in LogLevel.allCases {
            #expect(!LogLevel.isEnabled(.off, threshold: threshold))
        }
    }
}
