import XCTest
@testable import ConductorCore

final class PersistedStateTests: XCTestCase {
    private func sampleStore() -> WorkspaceStore {
        let tab = Tab(
            id: TabID("t1"), title: "zsh",
            rootSplit: .split(
                id: SplitID("s1"), axis: .vertical, ratio: 0.6,
                first: .leaf(PaneID("p1")),
                second: .leaf(PaneID("p2"))
            ),
            activePane: PaneID("p1")
        )
        let ws = Workspace(id: WorkspaceID("w1"), name: "proj", path: "/tmp/proj",
                           tabs: [tab], activeTab: TabID("t1"))
        return WorkspaceStore(workspaces: [ws], activeWorkspace: WorkspaceID("w1"))
    }

    func testDefaultVersionIsCurrent() {
        let state = PersistedState(store: sampleStore())
        XCTAssertEqual(state.version, PersistedState.currentVersion)
    }

    func testRoundTripPreservesFullTree() throws {
        let original = PersistedState(
            store: sampleStore(),
            paneCwds: ["p1": "/tmp/proj/src", "p2": "/tmp/proj"],
            paneSessions: ["p1": AgentSessionRef(agent: "claude", sessionID: "abc-123")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

}
