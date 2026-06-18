import XCTest
@testable import ConductorCore

final class AgentLaunchCommandSnapshotTests: XCTestCase {
    func testSanitizerKeepsResumeRelevantFlagsAndDropsPromptAndSecrets() {
        let snapshot = AgentLaunchCommandSanitizer.snapshot(
            agent: "codex",
            command: "codex --model gpt-5 --sandbox workspace-write --api-key sk-secret \"implement this\"",
            cwd: "/tmp/project")

        XCTAssertEqual(snapshot?.argv, ["codex", "--model", "gpt-5", "--sandbox", "workspace-write"])
        XCTAssertEqual(snapshot?.cwd, "/tmp/project")
    }

    func testResumeCommandUsesSanitizedLaunchFlags() {
        let snapshot = AgentLaunchCommandSanitizer.snapshot(
            agent: "codex",
            command: "codex --model gpt-5 --approval-policy never",
            cwd: nil)

        XCTAssertEqual(
            AgentLaunchCommandSanitizer.resumeCommand(
                agent: "codex",
                sessionID: "sess-1",
                launchCommand: snapshot),
            "codex --model gpt-5 --approval-policy never resume sess-1")
    }

    func testShellWordSplitHandlesQuotes() {
        XCTAssertEqual(ShellWords.split("codex --model 'gpt 5' \"hello world\""), [
            "codex", "--model", "gpt 5", "hello world",
        ])
    }
}
