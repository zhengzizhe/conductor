import XCTest
@testable import ConductorCore

final class AgentSessionLocatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Claude

    func testClaudeProjectSlugReplacesNonAlphanumerics() {
        XCTAssertEqual(
            AgentSessionLocator.claudeProjectSlug("/Users/me/Desktop/my.app_v2"),
            "-Users-me-Desktop-my-app-v2")
    }

    func testClaudeSessionIDPicksNewestJsonl() throws {
        let projectDir = tempDir.appendingPathComponent(
            AgentSessionLocator.claudeProjectSlug("/tmp/proj"), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let old = projectDir.appendingPathComponent("old-session.jsonl")
        let new = projectDir.appendingPathComponent("new-session.jsonl")
        try "x".write(to: old, atomically: true, encoding: .utf8)
        try "y".write(to: new, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        // 同名子目录（claude 会建）不应干扰
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("new-session", isDirectory: true),
            withIntermediateDirectories: true)

        XCTAssertEqual(
            AgentSessionLocator.claudeSessionID(cwd: "/tmp/proj", projectsRoot: tempDir),
            "new-session")
    }

    func testClaudeSessionIDNilWhenProjectMissing() {
        XCTAssertNil(AgentSessionLocator.claudeSessionID(cwd: "/no/such", projectsRoot: tempDir))
    }

    // MARK: - Codex

    private func writeRollout(_ name: String, id: String, cwd: String, ageSeconds: TimeInterval) throws {
        let dayDir = tempDir.appendingPathComponent("2026/06/10", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let url = dayDir.appendingPathComponent(name)
        let meta = #"{"timestamp":"t","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#
        try (meta + "\n{\"type\":\"other\"}\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -ageSeconds)], ofItemAtPath: url.path)
    }

    func testCodexSessionIDMatchesCwdNewestFirst() throws {
        try writeRollout("rollout-a.jsonl", id: "id-old", cwd: "/tmp/proj", ageSeconds: 3600)
        try writeRollout("rollout-b.jsonl", id: "id-new", cwd: "/tmp/proj", ageSeconds: 60)
        try writeRollout("rollout-c.jsonl", id: "id-other", cwd: "/elsewhere", ageSeconds: 10)

        XCTAssertEqual(
            AgentSessionLocator.codexSessionID(cwd: "/tmp/proj", sessionsRoot: tempDir),
            "id-new")
    }

    func testCodexSessionIDNilWhenNoCwdMatch() throws {
        try writeRollout("rollout-a.jsonl", id: "id-x", cwd: "/elsewhere", ageSeconds: 5)
        XCTAssertNil(AgentSessionLocator.codexSessionID(cwd: "/tmp/proj", sessionsRoot: tempDir))
    }

    // MARK: - AgentSessionRef

    func testResumeCommands() {
        XCTAssertEqual(
            AgentSessionRef(agent: "claude", sessionID: "abc").resumeCommand,
            "claude --resume abc")
        XCTAssertEqual(
            AgentSessionRef(agent: "codex", sessionID: "xyz").resumeCommand,
            "codex resume xyz")
        XCTAssertEqual(
            AgentSessionRef(agent: "gemini", sessionID: "n").resumeCommand,
            "gemini --resume n")
        XCTAssertEqual(
            AgentSessionRef(agent: "cursor", sessionID: "cur-1").resumeCommand,
            "cursor-agent --resume cur-1")
        XCTAssertEqual(
            AgentSessionRef(agent: "copilot", sessionID: "gh-1").resumeCommand,
            "copilot --resume gh-1")
        XCTAssertEqual(
            AgentSessionRef(agent: "grok", sessionID: "grok-1").resumeCommand,
            "grok -r grok-1")
        XCTAssertEqual(
            AgentSessionRef(agent: "opencode", sessionID: "open-1").resumeCommand,
            "opencode --session open-1")
        XCTAssertEqual(
            AgentSessionRef(agent: "amp", sessionID: "amp-1").resumeCommand,
            "amp threads continue amp-1")
        XCTAssertNil(AgentSessionRef(agent: "aider", sessionID: "n").resumeCommand)
    }

    func testLocateUnsupportedAgentReturnsNil() {
        XCTAssertNil(AgentSessionLocator.locate(
            agent: "gemini", cwd: "/tmp",
            claudeProjectsRoot: tempDir, codexSessionsRoot: tempDir))
    }
}
