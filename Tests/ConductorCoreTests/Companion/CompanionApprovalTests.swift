import XCTest
@testable import ConductorCore

final class CompanionApprovalTests: XCTestCase {
    func testPermissionCompactsToAllowPlusDenyWithMore() {
        let req = FeedRequest(kind: .permission(tool: "bash", category: .executeCommand, detail: "ls -la"))
        let c = CompanionApproval.compact(for: req)
        XCTAssertEqual(c.buttons.count, 2)
        XCTAssertEqual(c.buttons.first?.role, .allow)
        XCTAssertEqual(c.buttons.last?.role, .deny)
        XCTAssertTrue(c.hasMore, "permission 有 4 个权威按钮，紧凑后应提示还有更多")
    }

    func testExitPlanKeepsBothNoMore() {
        let c = CompanionApproval.compact(for: FeedRequest(kind: .exitPlan(plan: "step 1\nstep 2")))
        XCTAssertEqual(c.buttons.count, 2)
        XCTAssertFalse(c.hasMore)
    }

    func testQuestionCapsAtThree() {
        let many = FeedRequest(kind: .question(prompt: "选哪个？", options: ["A", "B", "C", "D", "E"]))
        let c = CompanionApproval.compact(for: many)
        XCTAssertEqual(c.buttons.count, 3)
        XCTAssertTrue(c.hasMore)
        XCTAssertTrue(c.buttons.allSatisfy { $0.role == .neutral })
    }

    func testQuestionFewKeepsAllNoMore() {
        let few = FeedRequest(kind: .question(prompt: "去吗？", options: ["去", "不去"]))
        let c = CompanionApproval.compact(for: few)
        XCTAssertEqual(c.buttons.count, 2)
        XCTAssertFalse(c.hasMore)
    }
}
