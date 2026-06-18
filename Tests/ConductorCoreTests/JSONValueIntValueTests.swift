@testable import ConductorCore
import Foundation
import XCTest

/// `JSONValue.intValue` 的 `.double` 分支防崩：inf/NaN/超 Int 范围不能 trap
/// （pi RPC 的数字字段如 attempt/maxAttempts/timeoutMs 是外来输入，畸形值不该崩进程）。
final class JSONValueIntValueTests: XCTestCase {
    func testNormalConversions() {
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertEqual(JSONValue.double(-8.0).intValue, -8)
        XCTAssertEqual(JSONValue.string("7").intValue, 7)
        XCTAssertNil(JSONValue.string("x").intValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
    }

    func testNonFiniteAndOverflowDoubleReturnsNilNotCrash() {
        XCTAssertNil(JSONValue.double(.infinity).intValue)
        XCTAssertNil(JSONValue.double(-.infinity).intValue)
        XCTAssertNil(JSONValue.double(.nan).intValue)
        XCTAssertNil(JSONValue.double(1e308).intValue)    // 远超 Int.max
        XCTAssertNil(JSONValue.double(-1e308).intValue)
    }
}
