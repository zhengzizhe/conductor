@testable import ConductorCore
import XCTest

final class PetStateReducerTests: XCTestCase {
    private func sig(_ a: AgentSignal.Activity, pending: Int = 0) -> AgentSignal {
        AgentSignal(activity: a, pendingApprovals: pending)
    }

    // MARK: 基础态映射

    func testWorkingIsThinking() {
        var r = PetStateReducer()
        XCTAssertEqual(r.reduce(sig(.working), now: 0), .thinking)
    }

    func testFailedIsSad() {
        var r = PetStateReducer()
        XCTAssertEqual(r.reduce(sig(.failed), now: 0), .sad)
    }

    func testFreshReadyIsIdleNotCelebrating() {
        // 首帧就是 ready（会话起好但还没跑过任何一轮）→ 不该误庆祝。
        var r = PetStateReducer()
        XCTAssertEqual(r.reduce(sig(.ready), now: 0), .idle)
    }

    func testIdleActivityIsIdle() {
        var r = PetStateReducer()
        XCTAssertEqual(r.reduce(sig(.idle), now: 0), .idle)
    }

    // MARK: 审批优先级（needsYou 盖过一切）

    func testPendingApprovalOverridesWorking() {
        var r = PetStateReducer()
        XCTAssertEqual(r.reduce(sig(.working, pending: 1), now: 0), .needsYou)
    }

    func testPendingApprovalOverridesFailed() {
        var r = PetStateReducer()
        XCTAssertEqual(r.reduce(sig(.failed, pending: 2), now: 0), .needsYou)
    }

    func testApprovalClearedWhileWorkingFallsBackToThinking() {
        var r = PetStateReducer()
        XCTAssertEqual(r.reduce(sig(.working, pending: 1), now: 0), .needsYou)
        XCTAssertEqual(r.reduce(sig(.working, pending: 0), now: 1), .thinking)
    }

    // MARK: 庆祝瞬态（working → ready 上升沿）

    func testWorkingToReadyCelebratesThenFallsToIdle() {
        var r = PetStateReducer(celebrateWindow: 4, sleepAfter: 90)
        XCTAssertEqual(r.reduce(sig(.working), now: 0), .thinking)
        XCTAssertEqual(r.reduce(sig(.ready), now: 1), .celebrating)   // 上升沿
        XCTAssertEqual(r.reduce(sig(.ready), now: 4), .celebrating)   // 窗内
        XCTAssertEqual(r.reduce(sig(.ready), now: 5), .idle)          // 窗满（now >= 1+4）回落
    }

    func testCelebrateInterruptedByNewWork() {
        var r = PetStateReducer(celebrateWindow: 10)
        _ = r.reduce(sig(.working), now: 0)
        XCTAssertEqual(r.reduce(sig(.ready), now: 1), .celebrating)
        // 庆祝窗还没满，又开始干活 → 立刻 thinking，不卡在庆祝。
        XCTAssertEqual(r.reduce(sig(.working), now: 2), .thinking)
    }

    func testAbortWorkingToStoppedDoesNotCelebrate() {
        var r = PetStateReducer()
        _ = r.reduce(sig(.working), now: 0)
        XCTAssertEqual(r.reduce(sig(.stopped), now: 1), .idle)  // stopped 不是 ready，不庆祝
    }

    func testSecondTurnRearmsCelebrate() {
        var r = PetStateReducer(celebrateWindow: 3)
        _ = r.reduce(sig(.working), now: 0)
        _ = r.reduce(sig(.ready), now: 1)            // celebrating
        _ = r.reduce(sig(.ready), now: 5)            // idle（窗满）
        _ = r.reduce(sig(.working), now: 6)          // thinking
        XCTAssertEqual(r.reduce(sig(.ready), now: 7), .celebrating)  // 第二轮重新庆祝
    }

    func testFailedClearsPendingCelebration() {
        var r = PetStateReducer(celebrateWindow: 10)
        _ = r.reduce(sig(.working), now: 0)
        XCTAssertEqual(r.reduce(sig(.ready), now: 1), .celebrating)
        // 庆祝窗内来了个 failed → 直接 sad，不被庆祝压住。
        XCTAssertEqual(r.reduce(sig(.failed), now: 2), .sad)
    }

    // MARK: 打盹计时

    func testQuietLongEnoughSleeps() {
        var r = PetStateReducer(sleepAfter: 90)
        XCTAssertEqual(r.reduce(sig(.ready), now: 0), .idle)
        XCTAssertEqual(r.reduce(sig(.ready), now: 89), .idle)
        XCTAssertEqual(r.reduce(sig(.ready), now: 90), .sleeping)   // 安静满 90s
    }

    func testActivityResetsSleepTimer() {
        // 睡着后来活会醒；再次安静时打盹计时从头算（用 working→stopped 避开庆祝，纯验计时重置）。
        var r = PetStateReducer(sleepAfter: 90)
        _ = r.reduce(sig(.ready), now: 0)
        XCTAssertEqual(r.reduce(sig(.ready), now: 90), .sleeping)     // 睡着
        XCTAssertEqual(r.reduce(sig(.working), now: 100), .thinking)  // 来活醒
        XCTAssertEqual(r.reduce(sig(.stopped), now: 110), .idle)      // 停了，重新计时
        XCTAssertEqual(r.reduce(sig(.stopped), now: 199), .idle)      // 距 110 才 89s
        XCTAssertEqual(r.reduce(sig(.stopped), now: 200), .sleeping)  // 距 110 满 90s
    }

    func testCelebrationDelaysSleepTimer() {
        // 打盹计时应从庆祝结束才起算，不把庆祝那几秒也算进静置。
        var r = PetStateReducer(celebrateWindow: 4, sleepAfter: 10)
        _ = r.reduce(sig(.working), now: 0)
        _ = r.reduce(sig(.ready), now: 1)             // celebrating，quietSince 清零
        XCTAssertEqual(r.reduce(sig(.ready), now: 5), .idle)   // 庆祝满，此刻才起算
        XCTAssertEqual(r.reduce(sig(.ready), now: 14), .idle)  // 距 5 才 9s
        XCTAssertEqual(r.reduce(sig(.ready), now: 15), .sleeping)  // 距 5 满 10s
    }

    func testSleepingWakesOnWork() {
        var r = PetStateReducer(sleepAfter: 10)
        _ = r.reduce(sig(.ready), now: 0)
        XCTAssertEqual(r.reduce(sig(.ready), now: 10), .sleeping)
        XCTAssertEqual(r.reduce(sig(.working), now: 11), .thinking)  // 来活立刻醒
    }
}
