@testable import ConductorApp
import XCTest

@MainActor
final class TerminalResizeFreezeTests: XCTestCase {
    private final class Participant: TerminalResizeFreezeParticipant {
        var didEndCount = 0
        func resizeFreezeDidEnd() { didEndCount += 1 }
    }

    func testFreezeDefersAndNotifiesOnUnfreeze() async throws {
        let freeze = TerminalResizeFreeze()
        let participant = Participant()
        freeze.register(participant)

        freeze.freeze(for: 0.05)
        XCTAssertTrue(freeze.isFrozen)
        XCTAssertEqual(participant.didEndCount, 0)

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(freeze.isFrozen)
        XCTAssertEqual(participant.didEndCount, 1)
    }

    func testRepeatedFreezeExtendsDeadlineAndNotifiesOnce() async throws {
        let freeze = TerminalResizeFreeze()
        let participant = Participant()
        freeze.register(participant)

        freeze.freeze(for: 0.08)
        try await Task.sleep(nanoseconds: 30_000_000)
        freeze.freeze(for: 0.15)   // 动画期间再次触发 → 顺延，不提前解冻

        try await Task.sleep(nanoseconds: 90_000_000)   // 第一次的 deadline 已过
        XCTAssertTrue(freeze.isFrozen)
        XCTAssertEqual(participant.didEndCount, 0)

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(freeze.isFrozen)
        XCTAssertEqual(participant.didEndCount, 1)
    }
}
