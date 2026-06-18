@testable import ConductorApp
import XCTest

final class AIAgentMenuPresentationTests: XCTestCase {
    func testSessionTitleIncludesAgentTitle() {
        let agent = LaunchableAgent(
            id: "codex",
            title: "Codex CLI",
            command: "codex",
            logo: "codex",
            fallbackSystemImage: "terminal")

        XCTAssertEqual(AIAgentMenuPresentation.sessionTitle(for: agent), "新建Codex CLI会话")
    }
}
