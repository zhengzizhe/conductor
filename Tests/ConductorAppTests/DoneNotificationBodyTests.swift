@testable import ConductorApp
import XCTest

/// 完成通知 body 组装：优先 agent 最后一句，否则回退文案；末尾附耗时。
final class DoneNotificationBodyTests: XCTestCase {
    func testPrefersLastAssistant() {
        let body = AppCoordinator.doneNotificationBody(
            lastAssistant: "已修复登录超时，加了重试。", fallback: "可以查看结果了", durationSuffix: "耗时 2 分")
        XCTAssertEqual(body, "已修复登录超时，加了重试。\n耗时 2 分")
    }

    func testFallsBackWhenNoLastAssistant() {
        let body = AppCoordinator.doneNotificationBody(
            lastAssistant: nil, fallback: "可以查看结果了", durationSuffix: "耗时 5 秒")
        XCTAssertEqual(body, "可以查看结果了\n耗时 5 秒")
    }

    func testBlankLastAssistantFallsBack() {
        let body = AppCoordinator.doneNotificationBody(
            lastAssistant: "   \n ", fallback: "可以查看结果了", durationSuffix: nil)
        XCTAssertEqual(body, "可以查看结果了")
    }

    func testTrimsLastAssistant() {
        let body = AppCoordinator.doneNotificationBody(
            lastAssistant: "  完成了  ", fallback: "x", durationSuffix: nil)
        XCTAssertEqual(body, "完成了")
    }

    func testNoDurationSuffix() {
        let body = AppCoordinator.doneNotificationBody(
            lastAssistant: "干完了", fallback: "x", durationSuffix: nil)
        XCTAssertEqual(body, "干完了")
    }

    func testEmptyFallbackWithDurationOnly() {
        let body = AppCoordinator.doneNotificationBody(
            lastAssistant: nil, fallback: "", durationSuffix: "耗时 1 分")
        XCTAssertEqual(body, "耗时 1 分")
    }
}
