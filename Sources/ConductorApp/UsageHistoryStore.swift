import Combine
import ConductorCore
import Foundation

/// 一次用量采样：从 `UsageSnapshot` 抽出可画趋势的关键信号（各窗已用% + 额度/消费）。
public struct UsageSample: Codable, Equatable, Sendable {
    public var at: Date
    public var primaryPercent: Double?
    public var secondaryPercent: Double?
    public var tertiaryPercent: Double?
    /// providerCost.used（消费/余额金额）。
    public var costUsed: Double?
    /// providerCost.limit（<=0 表示无上限，存 0）。
    public var costLimit: Double?
    public var currency: String?
}

/// 账号用量历史：每次成功拉到 `UsageSnapshot` 就采一笔（按 15 分钟时间桶去重），落盘到
/// `Application Support/conductor/usage-history.json`，供 provider 行里的趋势图展示。
///
/// CodexBar 的历史图靠各 provider 的服务端时间序列接口；conductor 改用「自采样」——把我们每次
/// 已经拉到的快照累积起来画趋势，对全部 49 个 provider 通用，且不额外发请求。
@MainActor
public final class UsageHistoryStore: ObservableObject {
    public static let shared = UsageHistoryStore()

    @Published public private(set) var series: [String: [UsageSample]] = [:]

    /// 同一 provider 15 分钟内的采样合并为一笔（覆盖最后一笔），避免反复开面板灌爆历史。
    private let bucketSeconds: TimeInterval = 15 * 60
    private let maxPoints = 800
    private let maxAgeDays: TimeInterval = 45
    private var dirty = false

    private init() { series = Self.load() }

    /// 记一笔采样到内存（不立刻写盘；批量结束后调 `persist()`）。
    public func record(id: String, snapshot: UsageSnapshot, now: Date = Date()) {
        let sample = UsageSample(
            at: now,
            primaryPercent: snapshot.primary?.usedPercent,
            secondaryPercent: snapshot.secondary?.usedPercent,
            tertiaryPercent: snapshot.tertiary?.usedPercent,
            costUsed: snapshot.providerCost?.used,
            costLimit: snapshot.providerCost.map { $0.limit > 0 ? $0.limit : 0 },
            currency: snapshot.providerCost?.currencyCode)
        // 全空快照不记。
        guard sample.primaryPercent != nil || sample.secondaryPercent != nil
            || sample.tertiaryPercent != nil || sample.costUsed != nil else { return }

        var arr = self.series[id] ?? []
        if let last = arr.last, now.timeIntervalSince(last.at) < self.bucketSeconds {
            arr[arr.count - 1] = sample
        } else {
            arr.append(sample)
        }
        let cutoff = now.addingTimeInterval(-self.maxAgeDays * 86400)
        arr.removeAll { $0.at < cutoff }
        if arr.count > self.maxPoints { arr.removeFirst(arr.count - self.maxPoints) }
        self.series[id] = arr
        self.dirty = true
    }

    public func samples(for id: String) -> [UsageSample] { self.series[id] ?? [] }

    /// 把内存历史落盘（批量采样后调一次）。
    public func persist() {
        guard self.dirty else { return }
        self.dirty = false
        Self.save(self.series)
    }

    // MARK: - 磁盘

    private static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conductor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-history.json")
    }

    private static func load() -> [String: [UsageSample]] {
        guard let data = try? Data(contentsOf: self.fileURL) else { return [:] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([String: [UsageSample]].self, from: data)) ?? [:]
    }

    private static func save(_ series: [String: [UsageSample]]) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(series) else { return }
        try? data.write(to: self.fileURL, options: .atomic)
    }
}
