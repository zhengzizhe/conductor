@testable import ConductorApp
import XCTest

@MainActor
final class TaskCardStoreTests: XCTestCase {
    func testCreatePersistsCards() throws {
        let url = try temporaryStoreURL()
        let store = TaskCardStore(fileURL: url)
        let card = store.create(workspaceID: "w-1")

        var edited = card
        edited.title = "Run tests"
        edited.prompt = "swift test"
        edited.executor = .agent("codex")
        store.upsert(edited)

        let reloaded = TaskCardStore(fileURL: url)
        XCTAssertEqual(reloaded.cards.count, 1)
        XCTAssertEqual(reloaded.cards[0].title, "Run tests")
        XCTAssertEqual(reloaded.cards[0].prompt, "swift test")
        XCTAssertEqual(reloaded.cards[0].workspaceID, "w-1")
        XCTAssertEqual(reloaded.cards[0].executor, .agent("codex"))
    }

    func testMarkRanUpdatesRunStats() throws {
        let url = try temporaryStoreURL()
        let store = TaskCardStore(fileURL: url)
        let card = store.create(workspaceID: nil)

        let ranAt = Date(timeIntervalSince1970: 100)
        store.markRan(card.id, at: ranAt)

        XCTAssertEqual(store.cards[0].runCount, 1)
        XCTAssertEqual(store.cards[0].lastRunAt, ranAt)
    }

    func testExecutorSelectionRoundTrips() {
        XCTAssertEqual(TaskCardExecutor(selectionID: "shell"), .shell)
        XCTAssertEqual(TaskCardExecutor(selectionID: "agent:codex"), .agent("codex"))
        XCTAssertEqual(TaskCardExecutor.agent("claude").selectionID, "agent:claude")
    }

    private func temporaryStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-task-card-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir.appendingPathComponent("task-cards.json")
    }
}
