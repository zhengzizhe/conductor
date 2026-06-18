import Combine
import ConductorCore
import Foundation

/// Feed 审批策略的持久化（`~/Library/Application Support/conductor/feed-policy.json`）。
/// url 为 nil 时纯内存（测试用）。
struct FeedPolicyStore {
    let url: URL?

    static var standard: FeedPolicyStore {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conductor", isDirectory: true)
        return FeedPolicyStore(url: dir.appendingPathComponent("feed-policy.json"))
    }

    static let inMemory = FeedPolicyStore(url: nil)

    func load() -> FeedPolicy {
        guard let url, let data = try? Data(contentsOf: url),
              let policy = try? JSONDecoder().decode(FeedPolicy.self, from: data)
        else { return .empty }
        return policy
    }

    func save(_ policy: FeedPolicy) {
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(policy) { try? data.write(to: url) }
    }
}

/// Feed 审批中枢：收口所有 agent 的待批请求。
/// - 命中策略/规则的请求自动处置、即刻返回；
/// - 需要人工的挂起（continuation），等 GUI/CLI `resolve` 或超时/断开 `cancel` 再放行 agent。
/// socket 的 `feed.request` handler 是 async，可直接 `await submit(...)` 挂起而不冻结主线程。
@MainActor
final class FeedCenter: ObservableObject {
    /// 当前待人工处置的请求（GUI 队列 + `feed.list` 读它）。
    @Published private(set) var pending: [FeedRequest] = []
    /// 审计环形缓冲。
    @Published private(set) var audit: [FeedAuditEntry] = []
    private(set) var engine: FeedPolicyEngine

    private var continuations: [String: CheckedContinuation<FeedDecision, Never>] = [:]
    private var deadlines: [String: Date] = [:]
    private let store: FeedPolicyStore
    private var expiryTimer: Timer?
    private static let maxAudit = 500
    /// 软超时秒数（无人理多久按默认动作=拒绝结束）。0 = 不超时。
    var defaultTimeout: TimeInterval = 120
    /// 有新的待人工处置请求入队时回调。
    var onPendingAdded: (() -> Void)?

    init(store: FeedPolicyStore = .standard) {
        self.store = store
        self.engine = FeedPolicyEngine(policy: store.load())
    }

    /// agent 请求审批。自动命中即刻返回；否则挂起等决策。
    func submit(_ request: FeedRequest, timeout: TimeInterval? = nil) async -> FeedDecision {
        switch engine.evaluate(request) {
        case let .auto(decision):
            recordAudit(request, decision: decision, auto: true)
            return decision
        case .prompt:
            return await withCheckedContinuation { (cont: CheckedContinuation<FeedDecision, Never>) in
                pending.append(request)
                continuations[request.id] = cont
                let t = timeout ?? defaultTimeout
                if t > 0 { deadlines[request.id] = request.createdAt.addingTimeInterval(t) }
                onPendingAdded?()
            }
        }
    }

    /// 人工（GUI/CLI）决策。命中记忆作用域则写规则并持久化。
    @discardableResult
    func resolve(id: String, decision: FeedDecision) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        let request = pending.remove(at: index)
        deadlines[id] = nil
        if let rule = engine.rememberedRule(for: request, decision: decision) {
            engine.remember(rule)
            store.save(engine.policy)
        }
        recordAudit(request, decision: decision, auto: false)
        continuations.removeValue(forKey: id)?.resume(returning: decision)
        return true
    }

    /// 取消（客户端断开 / 超时）：按拒绝结束，不记忆。
    func cancel(id: String, reason: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        deadlines[id] = nil
        recordAudit(request, decision: .deny(.once), auto: true, note: reason)
        continuations.removeValue(forKey: id)?.resume(returning: .deny(.once))
    }

    /// 把超过软超时的待批项按默认动作（拒绝）结束。
    func expireOverdue(now: Date = Date()) {
        for id in deadlines.filter({ $0.value <= now }).map(\.key) {
            cancel(id: id, reason: "timeout")
        }
    }

    func pendingRequests() -> [FeedRequest] { pending }

    /// 手动覆盖策略（设置 UI 用）。
    func updatePolicy(_ policy: FeedPolicy) {
        engine.policy = policy
        store.save(policy)
    }

    func startExpiryTimer() {
        guard expiryTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireOverdue() }
        }
        timer.tolerance = 2
        expiryTimer = timer
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    private func recordAudit(_ request: FeedRequest, decision: FeedDecision,
                             auto: Bool, note: String? = nil) {
        audit.append(FeedAuditEntry(
            summary: request.summary, agent: request.agent, paneID: request.paneID,
            decision: decision.auditString, auto: auto, note: note))
        if audit.count > Self.maxAudit { audit.removeFirst(audit.count - Self.maxAudit) }
    }
}
