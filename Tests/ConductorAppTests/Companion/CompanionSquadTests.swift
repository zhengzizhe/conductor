@testable import ConductorApp
import ConductorCore
import XCTest

/// `CompanionController.buildRoster` 的纯逻辑：把 pane 世界的多组状态合并成"小队"，
/// 每个在线会话一员，审批/跑完/干活各成一行、各不抢占。这是"只认一个会话"的根治，
/// 也最易错（去重、抢占、裁剪、排序），所以穷尽式单测。
final class CompanionSquadTests: XCTestCase {
    private func perm(_ id: String, pane: String?, detail: String = "ls",
                      tool: String = "bash") -> FeedRequest {
        FeedRequest(id: id, paneID: pane, agent: "claude",
                    kind: .permission(tool: tool, category: .executeCommand, detail: detail))
    }

    private func build(thinking: [String] = [], done: [String] = [],
                       feed: [FeedRequest] = [], terminal: [FeedRequest] = [],
                       results: [String: String] = [:], titles: [String: String] = [:],
                       cap: Int = 5) -> CompanionRoster {
        CompanionController.buildRoster(
            thinking: thinking, done: done, feedPending: feed, terminalApprovals: terminal,
            results: results, titles: titles, fallbackTitle: "会话", cap: cap)
    }

    private func isWorking(_ m: CompanionMember) -> Bool {
        if case .working = m.state { return true }; return false
    }
    private func approvalRequest(_ m: CompanionMember) -> FeedRequest? {
        if case let .needsApproval(req, _) = m.state { return req }; return nil
    }
    private func doneReply(_ m: CompanionMember) -> String?? {
        if case let .done(reply) = m.state { return .some(reply) }; return .none
    }

    // MARK: 基础

    func testEmpty() {
        let r = build()
        XCTAssertTrue(r.members.isEmpty)
        XCTAssertEqual(r.overflow, 0)
    }

    func testSingleWorking() {
        let r = build(thinking: ["p1"], titles: ["p1": "auth-fix"])
        XCTAssertEqual(r.members.count, 1)
        XCTAssertTrue(isWorking(r.members[0]))
        XCTAssertEqual(r.members[0].paneID, "p1")
        XCTAssertEqual(r.members[0].title, "auth-fix")
        XCTAssertEqual(r.members[0].mood, .thinking)
    }

    func testMultipleWorkingSortedByPane() {
        let r = build(thinking: ["p3", "p1", "p2"])
        XCTAssertEqual(r.members.map(\.paneID), ["p1", "p2", "p3"])
        XCTAssertTrue(r.members.allSatisfy(isWorking))
    }

    func testTitleFallbackWhenMissing() {
        let r = build(thinking: ["p1"])
        XCTAssertEqual(r.members[0].title, "会话")
    }

    // MARK: 审批

    func testFeedApprovalBecomesMember() {
        let r = build(feed: [perm("a1", pane: "p1")], titles: ["p1": "migrate"])
        XCTAssertEqual(r.members.count, 1)
        XCTAssertEqual(approvalRequest(r.members[0])?.id, "a1")
        XCTAssertEqual(r.members[0].title, "migrate")
        XCTAssertEqual(r.members[0].mood, .needsYou)
    }

    func testApprovalWithoutPaneUsesToolName() {
        let r = build(feed: [perm("a1", pane: nil, tool: "WebFetch")])
        XCTAssertEqual(r.members.count, 1)
        XCTAssertNil(r.members[0].paneID)
        XCTAssertEqual(r.members[0].title, "WebFetch")
    }

    func testApprovalSupersedesWorkingForSamePane() {
        // p2 在思考又有待审批 → 只显示审批那一员，不重复成 working。
        let r = build(thinking: ["p1", "p2"], feed: [perm("a1", pane: "p2")])
        XCTAssertEqual(r.members.count, 2)
        let p2 = r.members.first { $0.paneID == "p2" }
        XCTAssertNotNil(approvalRequest(p2!))                 // p2 = 审批
        XCTAssertTrue(isWorking(r.members.first { $0.paneID == "p1" }!))   // p1 仍 working
    }

    func testTerminalApprovalIncludedAndFlagged() {
        let term = perm("codex-terminal:p5:pwd", pane: "p5", detail: "pwd")
        let r = build(thinking: ["p5"], terminal: [term])
        XCTAssertEqual(r.members.count, 1)
        if case let .needsApproval(_, terminal) = r.members[0].state {
            XCTAssertTrue(terminal)
        } else { XCTFail("应是审批成员") }
    }

    func testTwoConcurrentApprovalsBothShown() {
        // 痛点根治：两个会话同时等审批，两员都在、各点各的。
        let r = build(feed: [perm("a1", pane: "p1"), perm("a2", pane: "p2")])
        XCTAssertEqual(r.members.count, 2)
        XCTAssertEqual(Set(r.members.compactMap { approvalRequest($0)?.id }), ["a1", "a2"])
    }

    func testDuplicateRequestIDDeduped() {
        let dup = perm("a1", pane: "p1")
        let r = build(feed: [dup], terminal: [dup])
        XCTAssertEqual(r.members.count, 1)
    }

    // MARK: 跑完 / 回复

    func testDoneCarriesReply() {
        let r = build(done: ["p1"], results: ["p1": "改好啦"], titles: ["p1": "tests"])
        XCTAssertEqual(r.members.count, 1)
        XCTAssertEqual(doneReply(r.members[0]), .some("改好啦"))
        XCTAssertEqual(r.members[0].mood, .celebrating)
    }

    func testFreshReplyAloneMakesDoneMember() {
        // 通知来了但 pane 未必进 unseenDone（可能可见）——有新鲜回复也成跑完一员。
        let r = build(results: ["p7": "done"])
        XCTAssertEqual(r.members.count, 1)
        XCTAssertEqual(r.members[0].paneID, "p7")
    }

    func testThinkingPaneSuppressesStaleResult() {
        // 同一 pane 又开跑 → 旧回复作废，不显示跑完，只显示干活。
        let r = build(thinking: ["p1"], done: ["p1"], results: ["p1": "旧回复"])
        XCTAssertEqual(r.members.count, 1)
        XCTAssertTrue(isWorking(r.members[0]))
    }

    func testApprovalSupersedesDone() {
        let r = build(done: ["p1"], feed: [perm("a1", pane: "p1")], results: ["p1": "x"])
        XCTAssertEqual(r.members.count, 1)
        XCTAssertNotNil(approvalRequest(r.members[0]))
    }

    // MARK: 排序 / 容量

    func testDisplayOrderWorkingThenDoneThenApproval() {
        // 展示序：干活在最外、跑完居中、审批贴队长（最后 = 最靠近头顶）。
        let r = build(thinking: ["p1"], done: ["p2"], feed: [perm("a1", pane: "p3")],
                      results: ["p2": "ok"])
        XCTAssertEqual(r.members.map(\.displayRank), [0, 1, 2])
        XCTAssertTrue(isWorking(r.members[0]))
        XCTAssertNotNil(approvalRequest(r.members.last!))
    }

    func testCapKeepsApprovalDropsWorking() {
        // 超容量按 keepPriority 折叠：审批永不掉，先折干活。
        let r = build(thinking: ["p1", "p2", "p4"], feed: [perm("a1", pane: "p9")], cap: 2)
        XCTAssertEqual(r.members.count, 2)
        XCTAssertEqual(r.overflow, 2)
        XCTAssertTrue(r.members.contains { approvalRequest($0)?.id == "a1" })  // 审批保住
    }

    func testZeroCap() {
        let r = build(thinking: ["p1", "p2"], cap: 0)
        XCTAssertTrue(r.members.isEmpty)
        XCTAssertEqual(r.overflow, 2)
    }
}
