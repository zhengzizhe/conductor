@testable import ConductorApp
import XCTest

final class NotificationTextTests: XCTestCase {
    private let fallback = "有新结果"

    func testShortSingleLineIsKept() {
        XCTAssertEqual(NotificationText.body("可以查看结果了", fallback: fallback), "可以查看结果了")
    }

    func testTwoShortLinesJoinWithSeparator() {
        XCTAssertEqual(
            NotificationText.body("可以查看结果了\n耗时 2 分 30 秒", fallback: fallback),
            "可以查看结果了 · 耗时 2 分 30 秒")
    }

    func testMultilineContentDumpFallsBack() {
        let dump = """
        修复了三个问题：
        1. 侧栏动画卡顿
        2. 通知内容过长
        3. 分隔条拖动果冻感
        """
        XCTAssertEqual(NotificationText.body(dump, fallback: fallback), fallback)
    }

    func testOverlongSingleLineFallsBack() {
        let long = String(repeating: "结果内容 ", count: 40)
        XCTAssertEqual(NotificationText.body(long, fallback: fallback), fallback)
    }

    func testEmptyBodyFallsBack() {
        XCTAssertEqual(NotificationText.body("  \n\n ", fallback: fallback), fallback)
    }

    func testInnerWhitespaceCollapses() {
        XCTAssertEqual(NotificationText.body("done    in\t3s", fallback: fallback), "done in 3s")
    }

    func testTitleTruncatesAndCollapses() {
        let long = "AI 已完成 · " + String(repeating: "x", count: 100)
        let title = NotificationText.title(long)
        XCTAssertLessThanOrEqual(title.count, NotificationText.titleLimit)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(NotificationText.title("AI  已完成 ·\npane"), "AI 已完成 · pane")
    }
}
