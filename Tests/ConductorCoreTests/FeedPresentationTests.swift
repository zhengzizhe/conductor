@testable import ConductorCore
import XCTest

final class FeedPresentationTests: XCTestCase {

    func testPermissionActions() {
        let req = FeedRequest(kind: .permission(tool: "Bash", category: .executeCommand, detail: "git push"))
        let actions = FeedPresentation.actions(for: req)
        XCTAssertEqual(actions.map(\.decision), [
            .allow(.once), .allow(.tool), .allow(.category), .deny(.once),
        ])
        XCTAssertEqual(actions.map(\.role), [.allow, .allow, .allow, .deny])
        XCTAssertTrue(actions[1].label.contains("Bash"))
        XCTAssertTrue(actions[2].label.contains("执行命令"))
        XCTAssertEqual(FeedPresentation.body(for: req), "git push")
        XCTAssertTrue(FeedPresentation.title(for: req).contains("Bash"))
    }

    func testExitPlanActions() {
        let req = FeedRequest(kind: .exitPlan(plan: "1. 改 A\n2. 改 B"))
        let actions = FeedPresentation.actions(for: req)
        XCTAssertEqual(actions.map(\.decision), [.allow(.once), .deny(.once)])
        XCTAssertEqual(FeedPresentation.body(for: req), "1. 改 A\n2. 改 B")
    }

    func testQuestionActionsOnePerOption() {
        let req = FeedRequest(kind: .question(prompt: "选哪个？", options: ["A", "B", "C"]))
        let actions = FeedPresentation.actions(for: req)
        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(actions.map(\.decision),
                       [.answer(optionIndex: 0), .answer(optionIndex: 1), .answer(optionIndex: 2)])
        XCTAssertEqual(actions.map(\.label), ["A", "B", "C"])
        XCTAssertTrue(actions.allSatisfy { $0.role == .neutral })
        XCTAssertEqual(FeedPresentation.body(for: req), "选哪个？")
    }

    func testQuestionNoOptionsYieldsNoButtons() {
        let req = FeedRequest(kind: .question(prompt: "?", options: []))
        XCTAssertTrue(FeedPresentation.actions(for: req).isEmpty)
    }
}
