@testable import ConductorApp
import ConductorCore
import XCTest

@MainActor
final class FeedCenterTests: XCTestCase {

    private func permRequest(_ tool: String = "Bash",
                             _ cat: FeedActionCategory = .executeCommand,
                             detail: String? = "git push",
                             agent: String = "claude",
                             createdAt: Date = Date()) -> FeedRequest {
        FeedRequest(agent: agent, kind: .permission(tool: tool, category: cat, detail: detail),
                    createdAt: createdAt)
    }

    /// 让挂起的 submit Task 跑到注册待批项为止。
    private func waitForPending(_ center: FeedCenter, count: Int = 1) async {
        var spins = 0
        while center.pending.count < count {
            await Task.yield()
            spins += 1
            XCTAssertLessThan(spins, 10_000, "submit 未在合理时间内挂起")
        }
    }

    // MARK: - 自动处置

    func testSubmitAutoAllowReturnsImmediately() async {
        var policy = FeedPolicy(); policy.categoryDefaults = [.readFile: .allow]
        let center = FeedCenter(store: FeedPolicyStore(url: nil))
        center.updatePolicy(policy)
        let decision = await center.submit(permRequest("Read", .readFile, detail: nil))
        XCTAssertEqual(decision, .allow(.once))
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.audit.count, 1)
        XCTAssertTrue(center.audit[0].auto)
    }

    // MARK: - 挂起 → 人工决策

    func testSubmitPromptThenResolveAllow() async {
        let center = FeedCenter(store: .inMemory)
        let req = permRequest()
        let task = Task { await center.submit(req) }
        await waitForPending(center)
        XCTAssertEqual(center.pendingRequests().count, 1)

        XCTAssertTrue(center.resolve(id: req.id, decision: .allow(.once)))
        let decision = await task.value
        XCTAssertEqual(decision, .allow(.once))
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.audit.last?.auto, false)
    }

    func testResolveUnknownIdReturnsFalse() {
        let center = FeedCenter(store: .inMemory)
        XCTAssertFalse(center.resolve(id: "nope", decision: .allow(.once)))
    }

    // MARK: - 取消 / 超时

    func testCancelResolvesAsDeny() async {
        let center = FeedCenter(store: .inMemory)
        let req = permRequest()
        let task = Task { await center.submit(req) }
        await waitForPending(center)

        center.cancel(id: req.id, reason: "disconnect")
        let decision = await task.value
        XCTAssertEqual(decision, .deny(.once))
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.audit.last?.note, "disconnect")
        XCTAssertEqual(center.audit.last?.auto, true)
    }

    func testExpireOverdueDenies() async {
        let center = FeedCenter(store: .inMemory)
        center.defaultTimeout = 100
        let base = Date(timeIntervalSince1970: 1_000_000)
        let req = permRequest(createdAt: base)
        let task = Task { await center.submit(req) }
        await waitForPending(center)

        center.expireOverdue(now: base.addingTimeInterval(50))   // 未到点：不动
        XCTAssertEqual(center.pending.count, 1)
        center.expireOverdue(now: base.addingTimeInterval(200))  // 过点：拒绝
        let decision = await task.value
        XCTAssertEqual(decision, .deny(.once))
        XCTAssertEqual(center.audit.last?.note, "timeout")
    }

    // MARK: - 记忆持久化（跨实例）

    func testResolveAlwaysPersistsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-policy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FeedPolicyStore(url: url)

        let center = FeedCenter(store: store)
        let req = permRequest("Read", .readFile, detail: nil)
        let task = Task { await center.submit(req) }
        await waitForPending(center)
        center.resolve(id: req.id, decision: .allow(.tool))   // 记住这个工具+类别
        _ = await task.value
        XCTAssertEqual(center.engine.policy.rules.count, 1)

        // 新实例从同一文件加载 → 同类请求自动放行，不再挂起
        let reloaded = FeedCenter(store: store)
        XCTAssertEqual(reloaded.engine.policy.rules.count, 1)
        let decision = await reloaded.submit(permRequest("Read", .readFile, detail: nil))
        XCTAssertEqual(decision, .allow(.once))
        XCTAssertTrue(reloaded.pending.isEmpty)
    }
}
