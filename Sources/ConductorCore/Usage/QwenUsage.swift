import Foundation

/// Qwen / 通义（Alibaba 百炼编码套餐）用量取数。摘自 CodexBar `Alibaba CodingPlan` 的 apiKey 路径，
/// 自足、不依赖 cookie：用 `DASHSCOPE_API_KEY`（或 `ALIBABA_QWEN_API_KEY` / `ALIBABA_CODING_PLAN_API_KEY`）
/// POST 百炼网关 `queryCodingPlanInstanceInfoV2`，从返回里取 5 小时 / 周 配额。
///
/// 解析采用递归深搜定位含配额字段的对象（并展开内嵌 JSON 字符串），避开 CodexBar 的 instance 选择逻辑。
/// 照搬字段名自 CodexBar，本机无 key 无法实跑验证。
public enum QwenUsageError: LocalizedError, Sendable {
    case missingToken
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到通义/Qwen 令牌，请设置 DASHSCOPE_API_KEY")
        case .unauthorized: L("通义令牌无效，或该区域不支持 API key 模式")
        case let .server(c): L("通义接口错误（%ld）", c)
        case .invalidResponse: L("通义用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum QwenUsageFetcher {
    private struct Region {
        let gateway: String
        let commodity: String
        let regionId: String
        let referer: String
    }

    private static let intl = Region(
        gateway: "https://modelstudio.console.alibabacloud.com",
        commodity: "sfm_codingplan_public_intl",
        regionId: "ap-southeast-1",
        referer: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan")
    private static let cn = Region(
        gateway: "https://bailian.console.aliyun.com",
        commodity: "sfm_codingplan_public_cn",
        regionId: "cn-beijing",
        referer: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")

    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        for key in ["DASHSCOPE_API_KEY", "ALIBABA_QWEN_API_KEY", "ALIBABA_CODING_PLAN_API_KEY"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return nil
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw QwenUsageError.missingToken }
        // 先国际站，失败再试国内站。
        var lastError: Error = QwenUsageError.invalidResponse
        for region in [intl, cn] {
            do {
                return try await fetchOnce(region: region, apiKey: apiKey, session: session)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private static func fetchOnce(region: Region, apiKey: String, session: URLSession) async throws
        -> CodexUsageSnapshot
    {
        var components = URLComponents(string: "\(region.gateway)/data/api.json")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: region.regionId),
        ]
        guard let url = components.url else { throw QwenUsageError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let body: [String: Any] = ["queryCodingPlanInstanceInfoRequest": ["commodityCode": region.commodity]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiKey, forHTTPHeaderField: "X-DashScope-API-Key")
        request.setValue(region.gateway, forHTTPHeaderField: "Origin")
        request.setValue(region.referer, forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QwenUsageError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw QwenUsageError.unauthorized }
        guard http.statusCode == 200 else { throw QwenUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析（递归深搜 + 展开内嵌 JSON）

    static func parse(_ data: Data) throws -> CodexUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw QwenUsageError.invalidResponse }

        // 登录态/区域不支持判定。
        if let dict = root as? [String: Any] {
            let msg = (firstString(["message", "msg", "statusMessage"], dict) ?? "").lowercased()
            let code = (firstString(["code", "status"], dict) ?? "").lowercased()
            if msg.contains("login") || msg.contains("log in") || code.contains("login") || code.contains("unauth") {
                throw QwenUsageError.unauthorized
            }
        }

        guard let quota = findQuotaDict(in: root) else { throw QwenUsageError.invalidResponse }

        func window(used usedKeys: [String], total totalKeys: [String], refresh refreshKeys: [String], fallbackSeconds: Int)
            -> CodexUsageSnapshot.Window?
        {
            guard let total = anyInt(totalKeys, quota), total > 0 else { return nil }
            let used = anyInt(usedKeys, quota) ?? 0
            let pct = max(0, min(100, Int((Double(used) / Double(total) * 100).rounded())))
            let reset = anyDate(refreshKeys, quota) ?? Date().addingTimeInterval(TimeInterval(fallbackSeconds))
            return CodexUsageSnapshot.Window(usedPercent: pct, resetAt: reset, windowSeconds: fallbackSeconds)
        }

        let session = window(
            used: ["per5HourUsedQuota", "perFiveHourUsedQuota"],
            total: ["per5HourTotalQuota", "perFiveHourTotalQuota"],
            refresh: ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"],
            fallbackSeconds: 5 * 3600)
        let weekly = window(
            used: ["perWeekUsedQuota"], total: ["perWeekTotalQuota"],
            refresh: ["perWeekQuotaNextRefreshTime"], fallbackSeconds: 7 * 24 * 3600)
            ?? window(
                used: ["perBillMonthUsedQuota", "perMonthUsedQuota"],
                total: ["perBillMonthTotalQuota", "perMonthTotalQuota"],
                refresh: ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"],
                fallbackSeconds: 30 * 24 * 3600)

        guard session != nil || weekly != nil else { throw QwenUsageError.invalidResponse }
        let plan = firstString(["planName", "plan_name", "packageName", "package_name"], quota)
        return CodexUsageSnapshot(planType: plan, session: session, weekly: weekly)
    }

    /// 递归找到第一个含 5 小时配额字段的对象；遇到能解析成 JSON 的字符串值会展开后继续找。
    private static func findQuotaDict(in any: Any) -> [String: Any]? {
        if let dict = any as? [String: Any] {
            if dict["per5HourTotalQuota"] != nil || dict["perFiveHourTotalQuota"] != nil
                || dict["perWeekTotalQuota"] != nil
            {
                return dict
            }
            for value in dict.values {
                if let found = findQuotaDict(in: expand(value)) { return found }
            }
        } else if let array = any as? [Any] {
            for value in array {
                if let found = findQuotaDict(in: expand(value)) { return found }
            }
        }
        return nil
    }

    /// 内嵌 JSON 字符串 → 解析成对象；否则原样返回。
    private static func expand(_ value: Any) -> Any {
        guard let s = value as? String,
              let first = s.trimmingCharacters(in: .whitespaces).first,
              first == "{" || first == "[",
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return value }
        return obj
    }

    private static func anyInt(_ keys: [String], _ dict: [String: Any]) -> Int? {
        for k in keys {
            if let i = dict[k] as? Int { return i }
            if let d = dict[k] as? Double { return Int(d) }
            if let s = dict[k] as? String, let i = Int(s) ?? Double(s).map({ Int($0) }) { return i }
        }
        return nil
    }

    private static func firstString(_ keys: [String], _ dict: [String: Any]) -> String? {
        for k in keys {
            if let s = dict[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// 刷新时间：可能是 epoch（秒/毫秒）或 ISO8601 字符串。
    private static func anyDate(_ keys: [String], _ dict: [String: Any]) -> Date? {
        for k in keys {
            if let ms = dict[k] as? Int { return epochDate(Double(ms)) }
            if let ms = dict[k] as? Double { return epochDate(ms) }
            if let s = dict[k] as? String {
                if let v = Double(s) { return epochDate(v) }
                let f = ISO8601DateFormatter()
                if let d = f.date(from: s) { return d }
            }
        }
        return nil
    }

    private static func epochDate(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }
}
