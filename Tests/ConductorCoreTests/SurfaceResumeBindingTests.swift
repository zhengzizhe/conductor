import XCTest
@testable import ConductorCore

final class SurfaceResumeBindingTests: XCTestCase {
    private var tempDir: URL!
    private var store: SurfaceResumeBindingStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-bindings-\(UUID().uuidString)", isDirectory: true)
        store = SurfaceResumeBindingStore(fileURL: tempDir.appendingPathComponent("bindings.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBindingRestoreCommandPreservesCwd() {
        let binding = SurfaceResumeBinding(
            paneID: "p1",
            kind: "tmux",
            checkpoint: "work",
            command: "tmux attach -t work",
            cwd: "/tmp/my project",
            autoResume: true,
            trusted: true)

        XCTAssertEqual(binding.restoreCommand, "cd '/tmp/my project' && tmux attach -t work")
    }

    func testStoreSetShowClear() throws {
        let binding = SurfaceResumeBinding(paneID: "p1", command: "tmux attach -t work")
        try store.set(binding)

        XCTAssertEqual(store.binding(for: "p1")?.command, "tmux attach -t work")
        XCTAssertEqual(try store.clear(paneID: "p1")?.paneID, "p1")
        XCTAssertNil(store.binding(for: "p1"))
    }
}
