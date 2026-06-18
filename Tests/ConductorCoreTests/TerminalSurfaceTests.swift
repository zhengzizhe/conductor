import XCTest
import Foundation
@testable import ConductorCore

@MainActor
final class TerminalSurfaceTests: XCTestCase {
    func testFakeRecordsLifecycle() {
        let surface = FakeSurface()
        surface.start(cwd: URL(fileURLWithPath: "/tmp"))
        surface.focus()
        surface.close()
        XCTAssertEqual(surface.startedCwd, URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(surface.focusCount, 1)
        XCTAssertTrue(surface.closed)
    }

    func testFakeFiresCallbacks() {
        let surface = FakeSurface()
        var title: String?
        var cwd: URL?
        var exitCode: Int32?
        surface.onTitleChange = { title = $0 }
        surface.onCwdChange = { cwd = $0 }
        surface.onExit = { exitCode = $0 }
        surface.simulateTitleChange("build running")
        surface.simulateCwdChange(URL(fileURLWithPath: "/proj"))
        surface.simulateExit(0)
        XCTAssertEqual(title, "build running")
        XCTAssertEqual(cwd, URL(fileURLWithPath: "/proj"))
        XCTAssertEqual(exitCode, 0)
    }
}
