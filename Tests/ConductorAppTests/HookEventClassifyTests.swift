@testable import ConductorApp
import XCTest

/// hook 事件分类：只有真正的 Stop(done) 才发完成通知；
/// busy 点亮思考、sessionStart(含恢复会话) 仅记会话不通知。
final class HookEventClassifyTests: XCTestCase {
    func testBusy() {
        XCTAssertEqual(AppCoordinator.classifyHookEvent(type: "busy"), .busy)
    }

    func testSessionStartVariantsDoNotNotify() {
        XCTAssertEqual(AppCoordinator.classifyHookEvent(type: "sessionStart"), .sessionStart)
        XCTAssertEqual(AppCoordinator.classifyHookEvent(type: "session-start"), .sessionStart)
        XCTAssertEqual(AppCoordinator.classifyHookEvent(type: "sessionstart"), .sessionStart)
    }

    func testDoneAndLegacyAndUnknown() {
        XCTAssertEqual(AppCoordinator.classifyHookEvent(type: "done"), .done)
        XCTAssertEqual(AppCoordinator.classifyHookEvent(type: nil), .done)        // 旧脚本无 type = Stop
        XCTAssertEqual(AppCoordinator.classifyHookEvent(type: "whatever"), .done)
    }
}
