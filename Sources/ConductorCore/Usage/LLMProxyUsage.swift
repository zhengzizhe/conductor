import Foundation

/// LLM Proxy（llm-api-key-proxy）用量取数。忠实转写 CodexBar `LLMProxy` provider，自足、纯 token：
/// 用 `LLM_PROXY_API_KEY` 走 `Bearer` 调 `{LLM_PROXY_BASE_URL}/v1/quota-stats`，
/// 聚合各上游 provider 的 quota_groups，取最小 remaining_percent 作为额度窗口。账号级（与具体 CLI 无关）。
///
/// 环境变量：`LLM_PROXY_API_KEY`（密钥，必需）、`LLM_PROXY_BASE_URL`（代理地址，必需）。
/// 凭证来源仅为环境变量 token（CodexBar 的 `ProviderTokenResolver.llmProxyResolution`
/// 走 `resolveEnv(LLMProxySettingsReader.apiKey)`，无 cookie/浏览器路径）。
public enum LLMProxyUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingBaseURL
    case invalidURL
    case server(Int)
    case apiError(String)
    case invalidResponse
    case parseFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: L("未找到 LLM Proxy 密钥，请设置环境变量 LLM_PROXY_API_KEY")
        case .missingBaseURL: L("未找到 LLM Proxy 地址，请设置环境变量 LLM_PROXY_BASE_URL")
        case .invalidURL: L("LLM Proxy 地址无效")
        case let .server(code): L("LLM Proxy 接口错误（%ld）", code)
        case let .apiError(m): L("LLM Proxy API 错误：%@", m)
        case .invalidResponse: L("LLM Proxy 用量接口返回异常")
        case let .parseFailed(m): L("LLM Proxy 解析错误：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum LLMProxyUsageFetcher {
    public static let apiKeyEnvironmentKey = "LLM_PROXY_API_KEY"
    public static let baseURLEnvironmentKey = "LLM_PROXY_BASE_URL"

    /// 是否配置了 LLM Proxy 凭证（密钥 + 地址都齐备才视为「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil && baseURL(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        clean(env[apiKeyEnvironmentKey])
    }

    static func baseURL(env: [String: String]) -> URL? {
        guard let raw = clean(env[baseURLEnvironmentKey]) else { return nil }
        return URL(string: raw)
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func quotaStatsURL(baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versionedBaseURL = path.split(separator: "/").last == "v1"
            ? baseURL
            : baseURL.appendingPathComponent("v1")
        return versionedBaseURL.appendingPathComponent("quota-stats")
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw LLMProxyUsageError.missingCredentials }
        guard let base = baseURL(env: env) else { throw LLMProxyUsageError.missingBaseURL }

        var request = URLRequest(url: quotaStatsURL(baseURL: base))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw LLMProxyUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as LLMProxyUsageError {
            throw e
        } catch {
            throw LLMProxyUsageError.network(error.localizedDescription)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMProxyUsageError.apiError("HTTP \(http.statusCode): \(responseSummary(data))")
        }
        return try parse(data)
    }

    // MARK: - 解析

    private struct QuotaStatsResponse: Decodable {
        struct ProviderStats: Decodable {
            struct Tokens: Decodable {
                let inputCached: Int?
                let inputUncached: Int?
                let output: Int?

                private enum CodingKeys: String, CodingKey {
                    case inputCached = "input_cached"
                    case inputUncached = "input_uncached"
                    case output
                }
            }

            struct QuotaGroup: Decodable {
                let remainingPercent: Double?
                let resetTime: String?

                private enum CodingKeys: String, CodingKey {
                    case remainingPercent = "remaining_percent"
                    case resetTime = "reset_time"
                }
            }

            let credentialCount: Int?
            let activeCount: Int?
            let exhaustedCount: Int?
            let totalRequests: Int?
            let tokens: Tokens?
            let approximateCost: Double?
            let quotaGroups: [QuotaGroup]?

            private enum CodingKeys: String, CodingKey {
                case credentialCount = "credential_count"
                case activeCount = "active_count"
                case exhaustedCount = "exhausted_count"
                case totalRequests = "total_requests"
                case tokens
                case approximateCost = "approx_cost"
                case quotaGroups = "quota_groups"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                credentialCount = try container.decodeIfPresent(Int.self, forKey: .credentialCount)
                activeCount = try container.decodeIfPresent(Int.self, forKey: .activeCount)
                exhaustedCount = try container.decodeIfPresent(Int.self, forKey: .exhaustedCount)
                totalRequests = try container.decodeIfPresent(Int.self, forKey: .totalRequests)
                tokens = try container.decodeIfPresent(Tokens.self, forKey: .tokens)
                approximateCost = try container.decodeIfPresent(Double.self, forKey: .approximateCost)
                quotaGroups = Self.decodeQuotaGroups(from: container)
            }

            private static func decodeQuotaGroups(from container: KeyedDecodingContainer<CodingKeys>)
                -> [QuotaGroup]?
            {
                if let groups = try? container.decodeIfPresent([QuotaGroup].self, forKey: .quotaGroups) {
                    return groups
                }
                let keyedGroups = try? container.decodeIfPresent(
                    [String: QuotaGroup].self,
                    forKey: .quotaGroups)
                return keyedGroups?.values.sorted { lhs, rhs in
                    (lhs.remainingPercent ?? .infinity) < (rhs.remainingPercent ?? .infinity)
                }
            }
        }

        struct Summary: Decodable {
            let totalRequests: Int?
            let approximateCost: Double?
            let totalTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case totalRequests = "total_requests"
                case approximateCost = "approx_cost"
                case totalTokens = "total_tokens"
            }
        }

        let providers: [String: ProviderStats]
        let summary: Summary?
    }

    private struct ProviderSummary {
        let name: String
        let requests: Int
        let tokens: Int
        let approximateCostUSD: Double?
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let decoded: QuotaStatsResponse
        do {
            decoded = try JSONDecoder().decode(QuotaStatsResponse.self, from: data)
        } catch {
            throw LLMProxyUsageError.parseFailed(error.localizedDescription)
        }

        let providers = decoded.providers
        let summaries = providers.map { name, stats in
            ProviderSummary(
                name: name,
                requests: stats.totalRequests ?? 0,
                tokens: tokenTotal(stats.tokens),
                approximateCostUSD: stats.approximateCost)
        }.sorted { lhs, rhs in
            if lhs.requests != rhs.requests { return lhs.requests > rhs.requests }
            return lhs.name < rhs.name
        }

        let totalRequests = decoded.summary?.totalRequests ?? summaries.reduce(0) { $0 + $1.requests }
        let totalTokens = decoded.summary?.totalTokens ?? summaries.reduce(0) { $0 + $1.tokens }
        let approximateCostUSD = decoded.summary?.approximateCost ?? {
            let sum = summaries.compactMap(\.approximateCostUSD).reduce(0, +)
            return sum > 0 ? sum : nil
        }()

        let credentialCount = providers.values.reduce(0) { $0 + ($1.credentialCount ?? 0) }
        let activeCredentialCount = providers.values.reduce(0) { $0 + ($1.activeCount ?? 0) }

        let quotaGroups = providers.values.flatMap { $0.quotaGroups ?? [] }
        let minRemaining = quotaGroups.compactMap(\.remainingPercent).min()
        let nextResetAt = quotaGroups.compactMap { parseDate($0.resetTime) }.min()

        // session（额度）按 remaining_percent 反推已用百分比 → primary。
        let primary = minRemaining.map { remaining -> RateWindow in
            RateWindow(
                title: L("额度"),
                usedPercent: max(0, min(100, 100 - remaining)),
                resetsAt: nextResetAt)
        }

        // weekly → secondary（请求数）、第三窗 → tertiary（token 数），均为文本窗。
        let secondary = RateWindow(
            title: L("请求"),
            usedPercent: 0,
            resetDescription: "\(formatInteger(totalRequests)) requests")
        let tertiary = RateWindow(
            title: L("Token"),
            usedPercent: 0,
            resetDescription: "\(formatInteger(totalTokens)) tokens")

        // 各上游 provider 明细 → extraRateWindows。
        let extraWindows = summaries.prefix(3).map { provider in
            NamedRateWindow(
                id: provider.name,
                title: provider.name,
                window: RateWindow(
                    usedPercent: 0,
                    resetDescription: providerSummaryText(provider)))
        }

        // CodexBar approximateCostUSD → ProviderCostSnapshot（limit=0 表示无上限，仅显示已用）。
        let providerCost = approximateCostUSD.map {
            ProviderCostSnapshot(
                used: $0,
                limit: 0,
                currencyCode: "USD",
                period: L("约消费"),
                resetsAt: nextResetAt)
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: Array(extraWindows),
            providerCost: providerCost,
            accountLabel: "\(activeCredentialCount)/\(credentialCount) active keys")
    }

    private static func tokenTotal(_ tokens: QuotaStatsResponse.ProviderStats.Tokens?) -> Int {
        (tokens?.inputCached ?? 0) + (tokens?.inputUncached ?? 0) + (tokens?.output ?? 0)
    }

    private static func providerSummaryText(_ provider: ProviderSummary) -> String {
        var pieces = [
            "\(formatInteger(provider.requests)) req",
            "\(formatInteger(provider.tokens)) tok",
        ]
        if let cost = provider.approximateCostUSD {
            pieces.append(String(format: "$%.2f", cost))
        }
        return pieces.joined(separator: " · ")
    }

    private static func formatInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = iso8601DateFormatter(fractionalSeconds: true).date(from: raw) {
            return date
        }
        return iso8601DateFormatter(fractionalSeconds: false).date(from: raw)
    }

    private static func iso8601DateFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        if fractionalSeconds {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        return formatter
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}
