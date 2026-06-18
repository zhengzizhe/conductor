import ConductorCore
import Foundation
import XCTest

final class PathDisplayTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    func testTilde() {
        XCTAssertEqual(PathDisplay.tilde(home), "~")
        XCTAssertEqual(PathDisplay.tilde(home + "/Desktop/conductor"), "~/Desktop/conductor")
        XCTAssertEqual(PathDisplay.tilde("/tmp/foo"), "/tmp/foo")
        // 不是真前缀（缺 "/" 边界）→ 原样，不误压
        XCTAssertEqual(PathDisplay.tilde(home + "extra"), home + "extra")
    }

    func testLastComponent() {
        XCTAssertEqual(PathDisplay.lastComponent(home), "~")
        XCTAssertEqual(PathDisplay.lastComponent("/a/b/conductor"), "conductor")
        XCTAssertEqual(PathDisplay.lastComponent("/a/b/"), "b")
    }
}
