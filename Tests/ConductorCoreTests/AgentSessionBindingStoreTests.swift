import XCTest
@testable import ConductorCore

final class AgentSessionBindingStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: AgentSessionBindingStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-bindings-\(UUID().uuidString)", isDirectory: true)
        store = AgentSessionBindingStore(fileURL: tempDir.appendingPathComponent("sessions.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRecordAndLoadBinding() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // capturedAt 默认是 Date()，两次单独构造会得到不同的微秒级时间（且 JSON 往返丢精度），
        // 故必须显式钉死时间并复用同一个实例，否则相等断言必挂。
        let launchCommand = AgentLaunchCommandSnapshot(
            agent: "codex", argv: ["codex", "--model", "gpt-5"], capturedAt: now)
        try store.record(AgentSessionHookPayload(
            paneID: "p1",
            agent: "codex",
            sessionID: "sess-1",
            cwd: "/tmp/project",
            transcriptPath: "/tmp/project/rollout.jsonl",
            isRunning: true,
            lifecycle: .running,
            launchCommand: launchCommand,
            updatedAt: now))

        XCTAssertEqual(store.ref(for: "p1"), AgentSessionRef(
            agent: "codex",
            sessionID: "sess-1",
            cwd: "/tmp/project",
            transcriptPath: "/tmp/project/rollout.jsonl",
            updatedAt: now,
            wasRunning: true,
            lifecycle: .running,
            launchCommand: launchCommand))
    }

    func testCleanupKeepsOnlyLivePanes() throws {
        try store.record(AgentSessionHookPayload(paneID: "p1", agent: "claude", sessionID: "a"))
        try store.record(AgentSessionHookPayload(paneID: "p2", agent: "codex", sessionID: "b"))

        try store.cleanup(keeping: ["p2"])

        XCTAssertNil(store.ref(for: "p1"))
        XCTAssertEqual(store.ref(for: "p2")?.sessionID, "b")
    }

    func testIgnoresIncompletePayload() throws {
        try store.record(AgentSessionHookPayload(paneID: "p1", agent: "codex", sessionID: " "))
        XCTAssertTrue(store.load().isEmpty)
    }
}
