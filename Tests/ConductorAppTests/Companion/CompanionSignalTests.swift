@testable import ConductorApp
import ConductorCore
import XCTest

/// `CompanionController.signal` 把 pane 世界三组状态映射成 `AgentSignal` 的纯逻辑。
final class CompanionSignalTests: XCTestCase {
    func testThinkingMapsToWorking() {
        XCTAssertEqual(CompanionController.signal(thinking: true, done: false, pending: 0).activity, .working)
    }

    func testDoneMapsToReady() {
        XCTAssertEqual(CompanionController.signal(thinking: false, done: true, pending: 0).activity, .ready)
    }

    func testThinkingTakesPrecedenceOverDone() {
        // 同时在思考又有跑完未看 → 仍算在干活（thinking 优先）。
        XCTAssertEqual(CompanionController.signal(thinking: true, done: true, pending: 0).activity, .working)
    }

    func testIdleWhenNothing() {
        XCTAssertEqual(CompanionController.signal(thinking: false, done: false, pending: 0).activity, .idle)
    }

    func testPendingCarriedThrough() {
        XCTAssertEqual(CompanionController.signal(thinking: false, done: false, pending: 3).pendingApprovals, 3)
        // 审批条数与活动态正交：在干活时也能带审批。
        XCTAssertEqual(CompanionController.signal(thinking: true, done: false, pending: 2).pendingApprovals, 2)
    }
}
