import Foundation

/// Synthetic（synthetic.new）用量取数。忠实摘自 CodexBar `Synthetic` provider，自足、不依赖 cookie：
/// 用环境变量 `SYNTHETIC_API_KEY` 走 `Bearer` 调 `https://api.synthetic.new/v2/quotas`，
/// 解析三档配额槽位 `[rolling-5h, weekly, search-hourly]`。账号级（与具体 CLI 无关）。
///
/// 凭证来源（与 CodexBar 一致）：仅环境变量 `SYNTHETIC_API_KEY`（token 模式，无 cookie 路径）。
/// 见 CodexBar `SyntheticSettingsReader.apiKeyKey` / `ProviderTokenResolver.syntheticResolution`。
///
/// 槽位 → 窗口映射（依 CodexBar `SyntheticProviderDescriptor`：sessionLabel="Five-hour quota"、
/// weeklyLabel="Weekly tokens"）：slot 0（rolling 5h）→ session，slot 1（weekly）→ weekly。
/// 缺失的槽位保持 nil，不把后一档提升到错误的标签上。
public enum SyntheticUsageError: LocalizedError, Sendable {
    case missingToken
    case invalidCredentials
    case server(Int)
    case invalidResponse
    case parseFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 Synthetic 令牌，请设置环境变量 SYNTHETIC_API_KEY")
        case .invalidCredentials: L("Synthetic 凭证无效，请检查 SYNTHETIC_API_KEY")
        case let .server(code): L("Synthetic 接口错误（%ld）", code)
        case .invalidResponse: L("Synthetic 用量接口返回异常")
        case let .parseFailed(m): L("解析 Synthetic 返回失败：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum SyntheticUsageFetcher {
    private static let quotaAPIURL = URL(string: "https://api.synthetic.new/v2/quotas")!

    /// 是否配置了 Synthetic 令牌（用于在工具面板里把 Synthetic 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        clean(env["SYNTHETIC_API_KEY"])
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw SyntheticUsageError.missingToken }

        var request = URLRequest(url: quotaAPIURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw SyntheticUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as SyntheticUsageError {
            throw e
        } catch {
            throw SyntheticUsageError.network(error.localizedDescription)
        }

        switch http.statusCode {
        case 200:
            do {
                return try parse(data)
            } catch let e as SyntheticUsageError {
                throw e
            } catch {
                throw SyntheticUsageError.parseFailed(error.localizedDescription)
            }
        case 401, 403:
            throw SyntheticUsageError.invalidCredentials
        default:
            throw SyntheticUsageError.server(http.statusCode)
        }
    }

    // MARK: - 解析

    /// 一档配额的「已用百分比 0...100」「窗口分钟」「重置时刻」「额度/美元成本」。
    private struct Quota {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Date?
        let cost: ProviderCostSnapshot?
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data, options: [])

        let root: [String: Any] = {
            if let dict = object as? [String: Any] { return dict }
            if let array = object as? [Any] { return ["quotas": array] }
            return [:]
        }()

        let planName = self.planName(from: root)

        let slots: [Quota?]
        if let prioritized = prioritizedQuotaSlots(from: root) {
            slots = prioritized.map { $0.flatMap(parseQuota) }
        } else {
            let quotas = fallbackQuotaObjects(from: root).compactMap(parseQuota)
            slots = [
                quotas.indices.contains(0) ? quotas[0] : nil,
                quotas.indices.contains(1) ? quotas[1] : nil,
            ]
        }

        guard slots.contains(where: { $0 != nil }) else {
            throw SyntheticUsageError.parseFailed("Missing quota data.")
        }

        // slot 0（rolling 5h）→ primary；slot 1（weekly）→ secondary；slot 2（search-hourly）→ tertiary。
        let slot0 = slots.indices.contains(0) ? slots[0] : nil
        let slot1 = slots.indices.contains(1) ? slots[1] : nil
        let slot2 = slots.indices.contains(2) ? slots[2] : nil
        let primary = window(slot0, now: now, fallbackSeconds: 5 * 3600)
        let secondary = window(slot1, now: now, fallbackSeconds: 7 * 86400)
        let tertiary = window(slot2, now: now, fallbackSeconds: 3600)

        guard primary != nil || secondary != nil || tertiary != nil else {
            throw SyntheticUsageError.invalidResponse
        }

        // 额度/美元成本：取首个带 cost 的槽位（与 CodexBar `quotas.first(where:{ $0.cost != nil })?.cost` 一致）。
        let providerCost = [slot0, slot1, slot2].compactMap { $0?.cost }.first

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: providerCost,
            planName: planName,
            updatedAt: now)
    }

    private static func window(_ quota: Quota?, now: Date, fallbackSeconds: Int) -> RateWindow? {
        guard let quota else { return nil }
        let windowSeconds = quota.windowMinutes.map { $0 * 60 } ?? fallbackSeconds
        let resetAt = quota.resetsAt ?? now.addingTimeInterval(TimeInterval(windowSeconds))
        return RateWindow(
            usedPercent: max(0, min(100, quota.usedPercent)),
            windowMinutes: windowSeconds / 60,
            resetsAt: resetAt)
    }

    /// 已知 Synthetic 形状下的槽位负载 `[rolling-5h, weekly, search-hourly]`；缺失的槽位保持 nil。
    /// 任一已知 key 都不出现时返回 nil，走 fallback 路径。
    private static func prioritizedQuotaSlots(from root: [String: Any]) -> [[String: Any]?]? {
        let dataDict = root["data"] as? [String: Any]
        let rolling = namedQuota(root["rollingFiveHourLimit"], label: "Rolling five-hour limit")
            ?? namedQuota(dataDict?["rollingFiveHourLimit"], label: "Rolling five-hour limit")
        let weekly = namedQuota(root["weeklyTokenLimit"], label: "Weekly token limit")
            ?? namedQuota(dataDict?["weeklyTokenLimit"], label: "Weekly token limit")
        let searchHourly = namedQuota((root["search"] as? [String: Any])?["hourly"], label: "Search hourly")
            ?? namedQuota((dataDict?["search"] as? [String: Any])?["hourly"], label: "Search hourly")
        let slots: [[String: Any]?] = [rolling, weekly, searchHourly]
        return slots.contains(where: { $0 != nil }) ? slots : nil
    }

    private static func fallbackQuotaObjects(from root: [String: Any]) -> [[String: Any]] {
        let dataDict = root["data"] as? [String: Any]
        let candidates: [Any?] = [
            root["quotas"],
            root["quota"],
            root["limits"],
            root["usage"],
            root["entries"],
            root["subscription"],
            root["data"],
            dataDict?["quotas"],
            dataDict?["quota"],
            dataDict?["limits"],
            dataDict?["usage"],
            dataDict?["entries"],
            dataDict?["subscription"],
        ]
        for candidate in candidates {
            let quotas = extractQuotaObjects(from: candidate)
            if !quotas.isEmpty { return quotas }
        }
        return []
    }

    private static func planName(from root: [String: Any]) -> String? {
        if let direct = firstString(in: root, keys: planKeys) { return direct }
        if let dataDict = root["data"] as? [String: Any],
           let plan = firstString(in: dataDict, keys: planKeys)
        {
            return plan
        }
        return nil
    }

    private static func parseQuota(_ payload: [String: Any]) -> Quota? {
        let percentUsed = normalizedPercent(firstDouble(in: payload, keys: percentUsedKeys))
        let percentRemaining = normalizedPercent(firstDouble(in: payload, keys: percentRemainingKeys))

        var usedPercent = percentUsed
        if usedPercent == nil, let remaining = percentRemaining {
            usedPercent = 100 - remaining
        }

        if usedPercent == nil {
            var limit = firstDouble(in: payload, keys: limitKeys)
            var used = firstDouble(in: payload, keys: usedKeys)
            var remaining = firstDouble(in: payload, keys: remainingKeys)

            if limit == nil, let used, let remaining {
                limit = used + remaining
            }
            if used == nil, let limit, let remaining {
                used = limit - remaining
            }
            if remaining == nil, let limit, let used {
                remaining = max(0, limit - used)
            }

            if let limit, let used, limit > 0 {
                usedPercent = (used / limit) * 100
            }
        }

        guard let usedPercent else { return nil }
        let clamped = max(0, min(usedPercent, 100))

        let resetsAt = firstDate(in: payload, keys: resetKeys)
        return Quota(
            usedPercent: clamped,
            windowMinutes: windowMinutes(from: payload),
            resetsAt: resetsAt,
            cost: providerCost(from: payload, usedPercent: clamped, resetsAt: resetsAt))
    }

    /// 额度/美元成本：仅在出现 `maxCredits` 上限键时构造（与 CodexBar `providerCost(...)` 一致）。
    /// used 优先取 `usedCredits`，否则用 limit-remaining，再否则按已用百分比折算。
    private static func providerCost(
        from payload: [String: Any],
        usedPercent: Double,
        resetsAt: Date?) -> ProviderCostSnapshot?
    {
        guard let limit = firstCurrency(in: payload, keys: costLimitKeys) else { return nil }

        let remaining = firstCurrency(in: payload, keys: costRemainingKeys)
        let usedFromPayload = firstCurrency(in: payload, keys: costUsedKeys)
        let used: Double = if let usedFromPayload {
            usedFromPayload
        } else if let remaining {
            max(0, limit - remaining)
        } else {
            (max(0, min(100, usedPercent)) / 100) * limit
        }

        return ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: "USD",
            period: "Weekly",
            resetsAt: resetsAt)
    }

    private static func firstCurrency(in payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = payload[key] else { continue }
            if let text = value as? String, let parsed = parseCurrency(text) { return parsed }
            if let number = doubleValue(value) { return number }
        }
        return nil
    }

    private static func parseCurrency(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }

    private static func isQuotaPayload(_ payload: [String: Any]) -> Bool {
        let checks = [limitKeys, usedKeys, remainingKeys, percentUsedKeys, percentRemainingKeys]
        return checks.contains { firstDouble(in: payload, keys: $0) != nil }
    }

    private static func windowMinutes(from payload: [String: Any]) -> Int? {
        if let minutes = firstInt(in: payload, keys: windowMinutesKeys) { return minutes }
        if let hours = firstDouble(in: payload, keys: windowHoursKeys) {
            return Int((hours * 60).rounded())
        }
        if let days = firstDouble(in: payload, keys: windowDaysKeys) {
            return Int((days * 24 * 60).rounded())
        }
        if let seconds = firstDouble(in: payload, keys: windowSecondsKeys) {
            return Int((seconds / 60).rounded())
        }
        if let text = firstString(in: payload, keys: windowStringKeys) {
            return windowMinutes(fromText: text)
        }
        return nil
    }

    private static func namedQuota(_ candidate: Any?, label: String) -> [String: Any]? {
        guard var payload = candidate as? [String: Any], isQuotaPayload(payload) else { return nil }
        if payload["label"] == nil, payload["name"] == nil {
            payload["label"] = label
        }
        return payload
    }

    private static func extractQuotaObjects(from candidate: Any?) -> [[String: Any]] {
        switch candidate {
        case let array as [[String: Any]]:
            var nestedQuotas: [[String: Any]] = []
            for entry in array {
                if isQuotaPayload(entry) {
                    nestedQuotas.append(entry)
                } else {
                    nestedQuotas.append(contentsOf: extractQuotaObjects(from: entry))
                }
            }
            return nestedQuotas
        case let array as [Any]:
            return array.flatMap { extractQuotaObjects(from: $0) }
        case let dict as [String: Any]:
            if isQuotaPayload(dict) {
                return [dict]
            }
            var nestedQuotas: [[String: Any]] = []
            for key in dict.keys.sorted() {
                nestedQuotas.append(contentsOf: extractQuotaObjects(from: dict[key]))
            }
            return nestedQuotas
        default:
            return []
        }
    }

    /// 解析 `"5hr"`、`"30min"`、`"2 days"` 这类时长。后缀按长度降序匹配，多字母单位优先于单字母别名。
    static func windowMinutes(fromText text: String) -> Int? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        for (suffix, multiplier) in windowSuffixMultipliers {
            guard normalized.hasSuffix(suffix) else { continue }
            let valueText = String(normalized.dropLast(suffix.count))
            guard let value = Double(valueText), value > 0 else { return nil }
            return Int((value * multiplier).rounded())
        }
        return nil
    }

    private static let windowSuffixMultipliers: [(suffix: String, multiplier: Double)] = {
        let raw: [(String, Double)] = [
            ("minutes", 1), ("minute", 1), ("mins", 1), ("min", 1), ("m", 1),
            ("hours", 60), ("hour", 60), ("hrs", 60), ("hr", 60), ("h", 60),
            ("days", 24 * 60), ("day", 24 * 60), ("d", 24 * 60),
        ]
        return raw
            .sorted { $0.0.count > $1.0.count }
            .map { (suffix: $0.0, multiplier: $0.1) }
    }()

    private static func normalizedPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value <= 1 { return value * 100 }
        return value
    }

    private static func firstString(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(payload[key]) { return value }
        }
        return nil
    }

    private static func firstDouble(in payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = doubleValue(payload[key]) { return value }
        }
        return nil
    }

    private static func firstInt(in payload: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(payload[key]) { return value }
        }
        return nil
    }

    private static func firstDate(in payload: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = payload[key], let date = dateValue(value) { return date }
        }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let number as Double:
            return number
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(trimmed)
        default:
            return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        default:
            return nil
        }
    }

    private static func dateValue(_ raw: Any) -> Date? {
        if let number = doubleValue(raw) {
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            if number > 1_000_000_000 {
                return Date(timeIntervalSince1970: number)
            }
        }
        if let string = raw as? String {
            if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return dateValue(number)
            }
            if let date = timestampParse(string) {
                return date
            }
        }
        return nil
    }

    // MARK: - ISO8601 时间戳解析

    private static func timestampParse(_ text: String) -> Date? {
        formatterBox.lock.lock()
        defer { formatterBox.lock.unlock() }
        return formatterBox.withFractional.date(from: text) ?? formatterBox.plain.date(from: text)
    }

    private static let formatterBox = ISO8601FormatterBox()

    private final class ISO8601FormatterBox: @unchecked Sendable {
        let lock = NSLock()
        let withFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        let plain: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    }

    // MARK: - Key 列表（忠实摘自 CodexBar SyntheticUsageParser）

    private static let planKeys = [
        "plan", "planName", "plan_name", "subscription", "subscriptionPlan",
        "tier", "package", "packageName",
    ]

    private static let percentUsedKeys = [
        "percentUsed", "usedPercent", "usagePercent", "usage_percent",
        "used_percent", "percent_used", "percent",
    ]

    private static let percentRemainingKeys = [
        "percentRemaining", "remainingPercent", "remaining_percent", "percent_remaining",
    ]

    private static let limitKeys = [
        "limit", "messageLimit", "message_limit", "messages", "maxRequests",
        "max_requests", "requestLimit", "request_limit", "quota", "max",
        "total", "capacity", "allowance",
    ]

    private static let usedKeys = [
        "used", "usage", "usedMessages", "used_messages", "messagesUsed",
        "messages_used", "requests", "requestCount", "request_count", "consumed", "spent",
    ]

    private static let remainingKeys = [
        "remaining", "left", "available", "balance",
    ]

    private static let resetKeys = [
        "resetAt", "reset_at", "resetsAt", "resets_at", "renewAt", "renew_at",
        "renewsAt", "renews_at", "nextTickAt", "next_tick_at", "nextRegenAt",
        "next_regen_at", "periodEnd", "period_end", "expiresAt", "expires_at",
        "endAt", "end_at",
    ]

    private static let costLimitKeys = [
        "maxCredits", "max_credits",
    ]

    private static let costRemainingKeys = [
        "remainingCredits", "remaining_credits",
    ]

    private static let costUsedKeys = [
        "usedCredits", "used_credits",
    ]

    private static let windowMinutesKeys = [
        "windowMinutes", "window_minutes", "periodMinutes", "period_minutes",
    ]

    private static let windowHoursKeys = [
        "windowHours", "window_hours", "periodHours", "period_hours",
    ]

    private static let windowDaysKeys = [
        "windowDays", "window_days", "periodDays", "period_days",
    ]

    private static let windowSecondsKeys = [
        "windowSeconds", "window_seconds", "periodSeconds", "period_seconds",
    ]

    private static let windowStringKeys = [
        "window", "windowLabel", "window_label", "period", "periodLabel", "period_label",
    ]
}
