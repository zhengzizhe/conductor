@testable import ConductorCore
import XCTest

final class FeedPolicyEngineTests: XCTestCase {

    private func perm(_ tool: String, _ cat: FeedActionCategory,
                      detail: String? = nil, agent: String? = "claude") -> FeedRequest {
        FeedRequest(agent: agent, kind: .permission(tool: tool, category: cat, detail: detail))
    }

    // MARK: - glob

    func testGlob() {
        XCTAssertTrue(FeedGlob.matches(pattern: "*", in: ""))
        XCTAssertTrue(FeedGlob.matches(pattern: "*", in: "anything goes"))
        XCTAssertTrue(FeedGlob.matches(pattern: "git*", in: "git push origin"))
        XCTAssertFalse(FeedGlob.matches(pattern: "git*", in: "ls -la"))
        XCTAssertTrue(FeedGlob.matches(pattern: "*push*", in: "git push origin main"))
        XCTAssertFalse(FeedGlob.matches(pattern: "*push*", in: "git pull"))
        XCTAssertTrue(FeedGlob.matches(pattern: "rm -rf ?", in: "rm -rf /"))
        XCTAssertFalse(FeedGlob.matches(pattern: "rm -rf ?", in: "rm -rf ab"))
        XCTAssertTrue(FeedGlob.matches(pattern: "npm run *test*", in: "npm run unit-test-ci"))
        XCTAssertTrue(FeedGlob.matches(pattern: "exact", in: "exact"))
        XCTAssertFalse(FeedGlob.matches(pattern: "exact", in: "exactly"))
    }

    // MARK: - 空策略 / 非 permission

    func testEmptyPolicyPromptsPermission() {
        let engine = FeedPolicyEngine()
        XCTAssertEqual(engine.evaluate(perm("Bash", .executeCommand)), .prompt)
    }

    func testExitPlanAndQuestionAlwaysPrompt() {
        var policy = FeedPolicy()
        policy.categoryDefaults[.executeCommand] = .allow   // 即使有默认放行
        let engine = FeedPolicyEngine(policy: policy)
        XCTAssertEqual(engine.evaluate(FeedRequest(kind: .exitPlan(plan: "做三件事"))), .prompt)
        XCTAssertEqual(engine.evaluate(FeedRequest(kind: .question(prompt: "选哪个？", options: ["A", "B"]))), .prompt)
    }

    // MARK: - 类别默认

    func testCategoryDefaults() {
        var policy = FeedPolicy()
        policy.categoryDefaults = [.readFile: .allow, .writeFile: .deny, .network: .ask]
        let engine = FeedPolicyEngine(policy: policy)
        XCTAssertEqual(engine.evaluate(perm("Read", .readFile)), .auto(.allow(.once)))
        XCTAssertEqual(engine.evaluate(perm("Write", .writeFile)), .auto(.deny(.once)))
        XCTAssertEqual(engine.evaluate(perm("Fetch", .network)), .prompt)
        XCTAssertEqual(engine.evaluate(perm("Bash", .executeCommand)), .prompt)   // 未配 = ask
    }

    // MARK: - 规则匹配 + deny 优先

    func testAllowRuleMatches() {
        var policy = FeedPolicy()
        policy.rules = [FeedRule(tool: "Read", disposition: .allow)]
        let engine = FeedPolicyEngine(policy: policy)
        XCTAssertEqual(engine.evaluate(perm("Read", .readFile)), .auto(.allow(.once)))
        XCTAssertEqual(engine.evaluate(perm("Write", .writeFile)), .prompt)   // 工具不匹配
    }

    func testDenyOverridesAllowWhenBothMatch() {
        var policy = FeedPolicy()
        policy.rules = [
            FeedRule(category: .executeCommand, disposition: .allow),
            FeedRule(tool: "Bash", commandGlob: "*rm -rf*", disposition: .deny),
        ]
        let engine = FeedPolicyEngine(policy: policy)
        // 普通命令：仅 allow 命中
        XCTAssertEqual(engine.evaluate(perm("Bash", .executeCommand, detail: "ls")), .auto(.allow(.once)))
        // 危险命令：allow 与 deny 都命中 → deny 赢
        XCTAssertEqual(engine.evaluate(perm("Bash", .executeCommand, detail: "sudo rm -rf /")), .auto(.deny(.once)))
    }

    func testRuleAgentScoping() {
        var policy = FeedPolicy()
        policy.rules = [FeedRule(agent: "codex", tool: "Read", disposition: .allow)]
        let engine = FeedPolicyEngine(policy: policy)
        XCTAssertEqual(engine.evaluate(perm("Read", .readFile, agent: "codex")), .auto(.allow(.once)))
        XCTAssertEqual(engine.evaluate(perm("Read", .readFile, agent: "claude")), .prompt)   // agent 不匹配
    }

    func testCommandGlobRule() {
        var policy = FeedPolicy()
        policy.rules = [FeedRule(category: .executeCommand, commandGlob: "git *", disposition: .allow)]
        let engine = FeedPolicyEngine(policy: policy)
        XCTAssertEqual(engine.evaluate(perm("Bash", .executeCommand, detail: "git status")), .auto(.allow(.once)))
        XCTAssertEqual(engine.evaluate(perm("Bash", .executeCommand, detail: "npm i")), .prompt)
    }

    // MARK: - 记忆规则

    func testRememberedRuleScopes() {
        let engine = FeedPolicyEngine()
        let req = perm("Bash", .executeCommand, detail: "git push")

        XCTAssertNil(engine.rememberedRule(for: req, decision: .allow(.once)))
        XCTAssertNil(engine.rememberedRule(for: req, decision: .answer(optionIndex: 0)))

        let toolRule = engine.rememberedRule(for: req, decision: .allow(.tool))
        XCTAssertEqual(toolRule?.tool, "Bash")
        XCTAssertEqual(toolRule?.category, .executeCommand)
        XCTAssertEqual(toolRule?.agent, "claude")
        XCTAssertEqual(toolRule?.disposition, .allow)
        XCTAssertEqual(toolRule?.persisted, true)

        let catRule = engine.rememberedRule(for: req, decision: .deny(.category))
        XCTAssertNil(catRule?.tool)                       // 全类别 → 不限工具
        XCTAssertEqual(catRule?.category, .executeCommand)
        XCTAssertEqual(catRule?.disposition, .deny)
    }

    func testRememberThenAutoResolves() {
        var engine = FeedPolicyEngine()
        let req = perm("Read", .readFile)
        XCTAssertEqual(engine.evaluate(req), .prompt)

        let rule = engine.rememberedRule(for: req, decision: .allow(.tool))!
        engine.remember(rule)
        XCTAssertEqual(engine.evaluate(req), .auto(.allow(.once)))
        XCTAssertEqual(engine.policy.rules.count, 1)

        // 改主意：同 agent/tool/category 记成 deny → 替换而非叠加
        let denyRule = engine.rememberedRule(for: req, decision: .deny(.tool))!
        engine.remember(denyRule)
        XCTAssertEqual(engine.policy.rules.count, 1)
        XCTAssertEqual(engine.evaluate(req), .auto(.deny(.once)))
    }

    // MARK: - FeedRequest 便捷访问器

    func testRequestAccessors() {
        let p = perm("Bash", .executeCommand, detail: "ls")
        XCTAssertEqual(p.tool, "Bash")
        XCTAssertEqual(p.category, .executeCommand)
        XCTAssertEqual(p.detail, "ls")

        let q = FeedRequest(kind: .question(prompt: "?", options: []))
        XCTAssertNil(q.tool)
        XCTAssertNil(q.category)
        XCTAssertNil(q.detail)
    }

    // MARK: - 持久化往返

    func testPolicyCodableRoundTrip() throws {
        var policy = FeedPolicy()
        policy.categoryDefaults = [.readFile: .allow, .executeCommand: .ask]
        policy.rules = [FeedRule(agent: "claude", tool: "Bash", category: .executeCommand,
                                 commandGlob: "git *", disposition: .allow, persisted: true)]
        let data = try JSONEncoder().encode(policy)
        let back = try JSONDecoder().decode(FeedPolicy.self, from: data)
        XCTAssertEqual(back, policy)
    }
}
