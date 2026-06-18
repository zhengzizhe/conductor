import Foundation

/// 富用量模型，移植自 CodexBar `UsageFetcher.swift` 的 RateWindow / NamedRateWindow /
/// ProviderCostSnapshot / UsageSnapshot。相比基础 `CodexUsageSnapshot`（仅 session/weekly 双窗），
/// 这里有三窗 + 额外命名窗 + 额度/美元(credits/cost)，能完整承载各 provider 的用量。
///
/// 与 CodexBar 的差异：`RateWindow` 自带可选 `title`（显示标签），省得把 ProviderMetadata 的
/// sessionLabel/weeklyLabel 也搬过来——provider 直接把标签塞进窗口即可。

/// 一个限流窗口（某周期的已用百分比 + 重置信息）。
public struct RateWindow: Sendable, Equatable {
    /// 显示标签，如 "Session" / "Weekly" / "Opus" / "Credits"；nil 时 UI 用位置默认名。
    public var title: String?
    /// 已用百分比 0...100。
    public var usedPercent: Double
    /// 窗口时长（分钟）；nil 表示无固定周期。
    public var windowMinutes: Int?
    /// 重置时刻。
    public var resetsAt: Date?
    /// 文本化的重置描述（部分 provider 只给文字）。
    public var resetDescription: String?

    public init(
        title: String? = nil,
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        resetDescription: String? = nil)
    {
        self.title = title
        self.usedPercent = max(0, min(100, usedPercent))
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }

    public var remainingPercent: Double { max(0, 100 - self.usedPercent) }
}

/// 额外的命名窗口（如 Claude 的 Daily Routines、各家的细分配额）。
public struct NamedRateWindow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var window: RateWindow

    public init(id: String, title: String, window: RateWindow) {
        self.id = id
        self.title = title
        self.window = window
    }
}

/// 额度 / 消费快照（credits、按量计费、消费上限）。移植自 CodexBar `ProviderCostSnapshot`。
public struct ProviderCostSnapshot: Sendable, Equatable {
    /// 已用金额（主单位，如美元）。
    public var used: Double
    /// 上限金额；<= 0 表示无明确上限（仅显示余额/已用）。
    public var limit: Double
    /// 货币代码，如 "USD" / "CNY"。
    public var currencyCode: String
    /// 周期描述，如 "Monthly" / "Spend limit" / "Balance"。
    public var period: String?
    public var resetsAt: Date?

    public init(
        used: Double,
        limit: Double,
        currencyCode: String = "USD",
        period: String? = nil,
        resetsAt: Date? = nil)
    {
        self.used = used
        self.limit = limit
        self.currencyCode = currencyCode
        self.period = period
        self.resetsAt = resetsAt
    }

    public var hasLimit: Bool { self.limit > 0 }
    public var usedPercent: Double {
        guard self.limit > 0 else { return 0 }
        return max(0, min(100, self.used / self.limit * 100))
    }
}

/// 一个 provider 的完整用量快照。移植自 CodexBar `UsageSnapshot`（取展示所需子集）。
public struct UsageSnapshot: Sendable, Equatable {
    public var primary: RateWindow?
    public var secondary: RateWindow?
    public var tertiary: RateWindow?
    public var extraRateWindows: [NamedRateWindow]
    public var providerCost: ProviderCostSnapshot?
    /// 套餐 / 计划名（如 "Pro" / "Max" / "Free"）。
    public var planName: String?
    /// 账号标识（邮箱 / 组织），可空。
    public var accountLabel: String?
    public var updatedAt: Date

    public init(
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        extraRateWindows: [NamedRateWindow] = [],
        providerCost: ProviderCostSnapshot? = nil,
        planName: String? = nil,
        accountLabel: String? = nil,
        updatedAt: Date = Date())
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraRateWindows = extraRateWindows
        self.providerCost = providerCost
        self.planName = planName
        self.accountLabel = accountLabel
        self.updatedAt = updatedAt
    }

    /// 是否完全没有可展示的数据。
    public var isEmpty: Bool {
        self.primary == nil && self.secondary == nil && self.tertiary == nil
            && self.extraRateWindows.isEmpty && self.providerCost == nil
    }

    /// 所有窗口（主/次/三 + 额外）按显示顺序展开，给 UI 迭代用。
    public var allWindows: [(title: String, window: RateWindow)] {
        var out: [(String, RateWindow)] = []
        if let primary { out.append((primary.title ?? L("会话"), primary)) }
        if let secondary { out.append((secondary.title ?? L("本周"), secondary)) }
        if let tertiary { out.append((tertiary.title ?? L("其它"), tertiary)) }
        for extra in self.extraRateWindows { out.append((extra.title, extra.window)) }
        return out
    }
}

public extension UsageSnapshot {
    /// 从 `CodexUsageSnapshot` 适配到通用 provider 用量模型。
    init(codexSnapshot snapshot: CodexUsageSnapshot) {
        func window(_ w: CodexUsageSnapshot.Window?, _ title: String) -> RateWindow? {
            guard let w else { return nil }
            return RateWindow(
                title: title,
                usedPercent: Double(w.usedPercent),
                windowMinutes: w.windowSeconds > 0 ? w.windowSeconds / 60 : nil,
                resetsAt: w.resetAt)
        }
        self.init(
            primary: window(snapshot.session, L("会话")),
            secondary: window(snapshot.weekly, L("本周")),
            planName: snapshot.planType)
    }
}
