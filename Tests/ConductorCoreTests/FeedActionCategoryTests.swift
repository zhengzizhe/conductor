@testable import ConductorCore
import XCTest

final class FeedActionCategoryTests: XCTestCase {
    func testKnownClaudeTools() {
        XCTAssertEqual(FeedActionCategory.infer(toolName: "Bash"), .executeCommand)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "Read"), .readFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "Grep"), .readFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "Glob"), .readFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "Write"), .writeFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "Edit"), .writeFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "MultiEdit"), .writeFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "WebFetch"), .network)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "WebSearch"), .network)
    }

    func testHeuristicFallback() {
        XCTAssertEqual(FeedActionCategory.infer(toolName: "run_shell_command"), .executeCommand)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "execute_bash"), .executeCommand)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "apply_patch"), .writeFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "create_file"), .writeFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "read_file"), .readFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "list_dir"), .readFile)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "http_get"), .network)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "fetch_url"), .network)
    }

    func testUnknownIsOther() {
        XCTAssertEqual(FeedActionCategory.infer(toolName: "Frobnicate"), .other)
        XCTAssertEqual(FeedActionCategory.infer(toolName: ""), .other)
    }
}
