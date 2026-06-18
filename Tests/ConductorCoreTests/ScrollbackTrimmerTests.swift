import XCTest
@testable import ConductorCore

final class ScrollbackTrimmerTests: XCTestCase {
    func testDropsTrailingBlankScreenRows() {
        let text = "a\nb\n\n   \n\n"
        XCTAssertEqual(ScrollbackTrimmer.trim(text), "a\nb")
    }

    func testKeepsOnlyLastMaxLines() {
        let text = (1...10).map(String.init).joined(separator: "\n")
        XCTAssertEqual(ScrollbackTrimmer.trim(text, maxLines: 3), "8\n9\n10")
    }

    func testEnforcesByteLimitKeepingNewest() {
        let text = (1...100).map { _ in String(repeating: "x", count: 50) }.joined(separator: "\n")
        let trimmed = ScrollbackTrimmer.trim(text, maxLines: 1000, maxBytes: 200)
        XCTAssertLessThanOrEqual(trimmed.utf8.count, 200)
        XCTAssertTrue(trimmed.hasSuffix(String(repeating: "x", count: 50)))
    }

    func testShortTextUnchanged() {
        XCTAssertEqual(ScrollbackTrimmer.trim("hello\nworld"), "hello\nworld")
    }

    func testDefaultsMatchSessionRestoreBudget() {
        XCTAssertEqual(ScrollbackTrimmer.defaultMaxLines, 4000)
        XCTAssertEqual(ScrollbackTrimmer.defaultMaxBytes, 400_000)
    }

    func testStripsTerminalColorOSC() {
        let text = "a\u{1B}]10;#ffffff\u{07}b\u{1B}]104\u{1B}\\c"
        XCTAssertEqual(ScrollbackTrimmer.trim(text), "abc")
    }

    func testWrapsANSIResetWhenReplayContainsEscapeState() {
        let reset = "\u{1B}[0m"
        let trimmed = ScrollbackTrimmer.trim("plain \u{1B}[31mred")
        XCTAssertTrue(trimmed.hasPrefix(reset))
        XCTAssertTrue(trimmed.hasSuffix(reset))
    }

    func testDropsDecorativeHorizontalRules() {
        let rule = "\u{1B}[0m\u{1B}[2m" + String(repeating: "─", count: 40) + "\u{1B}[0m"
        XCTAssertEqual(ScrollbackTrimmer.trim("before\n\(rule)\nafter"), "before\nafter")
    }

    func testKeepsReplaySeparatorWithText() {
        let separator = "\u{1B}[2m── 以上为上次会话回放（进程未恢复）──\u{1B}[0m"
        XCTAssertEqual(ScrollbackTrimmer.trim(separator), "\u{1B}[0m\(separator)\u{1B}[0m")
    }
}
