@testable import ConductorApp
import ConductorCore
import XCTest

/// 思考状态兜底回收：**只**在「agent 进程已不在前台」时熄灭（崩溃/被 kill/已退出）。
/// 绝不因「输出静止/安静」或「跑太久」熄灭——那会误杀仍在运行转圈的长任务（用户实测 bug）。
/// 完成由 Stop hook 权威熄灭；这里只按进程 liveness 兜底。
final class ThinkingPruneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }

    func testKeepsAliveAndRecent() {
        let p = PaneID("p1")
        let out = AppCoordinator.prunedThinking([p: at(5)], agents: [p: "claude"])
        XCTAssertEqual(Set(out.keys), [p])
    }

    func testDropsWhenAgentProcessGone() {
        let p = PaneID("p1")
        // 思考点亮中，但 agent 进程已不在前台（崩溃/被 kill/退出）→ 熄灭
        let out = AppCoordinator.prunedThinking([p: at(5)], agents: [:])
        XCTAssertTrue(out.isEmpty)
    }

    /// 回归核心：agent 单轮跑很久（远超过去的 600s 硬上限），期间没刷屏、Stop hook 还没来，
    /// 但进程仍在前台 → **必须保留转圈**（旧的时长 cutoff 会在这里误杀长任务）。
    func testKeepsAliveRegardlessOfDuration() {
        let p = PaneID("p1")
        let out = AppCoordinator.prunedThinking([p: at(3600)], agents: [p: "claude"])
        XCTAssertEqual(Set(out.keys), [p], "进程还活着就一直转，不按时长强熄")
    }

    func testMixedFleet() {
        let alive = PaneID("alive"), gone = PaneID("gone"), longRun = PaneID("longRun")
        let out = AppCoordinator.prunedThinking(
            [alive: at(30), gone: at(30), longRun: at(7200)],
            agents: [alive: "claude", longRun: "codex"])   // gone 不在 agents 里（进程没了）
        XCTAssertEqual(Set(out.keys), [alive, longRun], "活着的都留（含跑了 2 小时的），只熄进程没了的")
    }
}
