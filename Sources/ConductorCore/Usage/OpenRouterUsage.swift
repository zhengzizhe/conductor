import Foundation

/// OpenRouter 用量取数。忠实摘自 CodexBar `OpenRouter` provider，自足、不依赖 CodexBarCore：
/// 用 `OPENROUTER_API_KEY` 走 `Bearer` 调 `https://openrouter.ai/api/v1/credits` 读账号 credits（$ 余额），
/// 并尽力（带 1s 超时）调 `/key` 读 API key 级的限额（limit/usage）。账号级（与具体 CLI 无关）。
///
/// OpenRouter 是 credits（美元额度）模型，没有滑动时间窗：
/// usedPercent = used/limit*100；reset 用 now+30 天占位；weekly = nil。
/// 若 `/key` 给出了有效的 limit/usage，用它精算；否则回退到 `/credits` 的 total_usage/total_credits。
///
/// 环境变量：`OPENROUTER_API_KEY`（必需）；`OPENROUTER_API_URL`（可选覆盖端点，必须 HTTPS）；
/// `OPENROUTER_HTTP_REFERER` / `OPENROUTER_X_TITLE`（可选，作为 HTTP-Referer / X-Title 头）。
public enum OpenRouterUsageError: LocalizedError, Sendable {
    case missingToken
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 OpenRouter 令牌，请设置环境变量 OPENROUTER_API_KEY")
        case let .server(code): L("OpenRouter 接口错误（%ld）", code)
        case .invalidResponse: L("OpenRouter 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum OpenRouterUsageFetcher {
    private static let envKey = "OPENROUTER_API_KEY"
    private static let defaultBaseURL = "https://openrouter.ai/api/v1"
    private static let httpRefererEnvKey = "OPENROUTER_HTTP_REFERER"
    private static let clientTitleEnvKey = "OPENROUTER_X_TITLE"
    private static let defaultClientTitle = "Conductor"
    private static let creditsTimeout: TimeInterval = 15
    private static let keyTimeout: TimeInterval = 1.0
    /// 无时间窗，用 30 天占位的重置时刻。
    private static let placeholderWindowSeconds = 30 * 86400

    /// 是否配置了 OpenRouter 令牌（只读 env，用于在面板里把 OpenRouter 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        clean(env[envKey])
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func baseURL(env: [String: String]) -> URL {
        if let raw = clean(env["OPENROUTER_API_URL"]),
           let u = URL(string: raw), u.scheme?.lowercased() == "https"
        {
            return u
        }
        return URL(string: defaultBaseURL)!
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw OpenRouterUsageError.missingToken }

        let base = baseURL(env: env)
        let credits = try await fetchCredits(apiKey: apiKey, base: base, env: env, session: session)
        let key = await fetchKey(apiKey: apiKey, base: base, env: env, session: session)
        return makeSnapshot(credits: credits, key: key)
    }

    // MARK: - 请求

    private static func authorizedRequest(
        url: URL,
        apiKey: String,
        env: [String: String],
        timeout: TimeInterval) -> URLRequest
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let referer = clean(env[httpRefererEnvKey]) {
            request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        }
        let title = clean(env[clientTitleEnvKey]) ?? defaultClientTitle
        request.setValue(title, forHTTPHeaderField: "X-Title")
        return request
    }

    private static func fetchCredits(
        apiKey: String,
        base: URL,
        env: [String: String],
        session: URLSession) async throws -> CreditsData
    {
        let url = base.appendingPathComponent("credits")
        let request = authorizedRequest(url: url, apiKey: apiKey, env: env, timeout: creditsTimeout)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw OpenRouterUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as OpenRouterUsageError {
            throw e
        } catch {
            throw OpenRouterUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else { throw OpenRouterUsageError.server(http.statusCode) }
        do {
            return try JSONDecoder().decode(CreditsResponse.self, from: data).data
        } catch {
            throw OpenRouterUsageError.invalidResponse
        }
    }

    /// `/key` 是可选增强（带短超时）；任何失败都静默回退到 nil，不阻塞 credits。
    private static func fetchKey(
        apiKey: String,
        base: URL,
        env: [String: String],
        session: URLSession) async -> KeyData?
    {
        let url = base.appendingPathComponent("key")
        let request = authorizedRequest(url: url, apiKey: apiKey, env: env, timeout: keyTimeout)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(KeyResponse.self, from: data).data
        } catch {
            return nil
        }
    }

    // MARK: - 响应模型

    private struct CreditsResponse: Decodable { let data: CreditsData }

    private struct CreditsData: Decodable {
        let totalCredits: Double
        let totalUsage: Double
        enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage = "total_usage"
        }

        /// 已用百分比 0...100（total_usage/total_credits*100）。
        var usedPercent: Double {
            guard totalCredits > 0 else { return 0 }
            return min(100, (totalUsage / totalCredits) * 100)
        }
    }

    private struct KeyResponse: Decodable { let data: KeyData }

    private struct KeyData: Decodable {
        let limit: Double?
        let usage: Double?
        enum CodingKeys: String, CodingKey {
            case limit, usage
        }

        /// 仅当存在正的 limit 与非负 usage 时有效。
        var hasValidQuota: Bool {
            guard let limit, let usage else { return false }
            return limit > 0 && usage >= 0
        }

        /// API key 级别已用百分比 0...100（usage/limit*100）。
        var usedPercent: Double? {
            guard hasValidQuota, let limit, let usage else { return nil }
            return min(100, max(0, (usage / limit) * 100))
        }
    }

    // MARK: - 组装

    private static func makeSnapshot(credits: CreditsData, key: KeyData?) -> UsageSnapshot {
        // primary 窗：已用百分比。优先用 /key 的 limit/usage 精算；否则回退 /credits 的
        // total_usage/total_credits。OpenRouter 无滑动时间窗，沿用 now+30 天占位。
        let pct = key?.usedPercent ?? credits.usedPercent
        let primary = RateWindow(
            title: L("额度"),
            usedPercent: pct,
            windowMinutes: nil,
            resetsAt: Date().addingTimeInterval(TimeInterval(placeholderWindowSeconds)))

        // providerCost：真正的 credits（美元额度）。优先用 /key 的 usage/limit（更精确），
        // 否则回退 /credits 的 total_usage/total_credits。limit<=0 表示无明确上限，只显已用/余额。
        let cost: ProviderCostSnapshot = if key?.hasValidQuota == true,
                                            let limit = key?.limit, let usage = key?.usage
        {
            ProviderCostSnapshot(used: usage, limit: limit, currencyCode: "USD", period: "Balance")
        } else {
            ProviderCostSnapshot(
                used: credits.totalUsage,
                limit: credits.totalCredits,
                currencyCode: "USD",
                period: "Balance")
        }

        // 不再把余额塞进 planType，套餐名留空。
        return UsageSnapshot(primary: primary, providerCost: cost, planName: nil)
    }
}
