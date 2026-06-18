import Foundation

/// OpenAI（OpenAI API 平台用量，区别于 ChatGPT/Codex 订阅）用量取数。摘自 CodexBar `OpenAI`
/// provider（`Providers/OpenAI/`），自足、不依赖 cookie：用 `Bearer` 走
/// `https://api.openai.com/v1/dashboard/billing/credit_grants`，解析 API 额度
/// （total_granted / total_used / total_available）。账号级（与具体 CLI 无关）。
///
/// 环境变量（与 CodexBar `OpenAIAPISettingsReader.apiKeyEnvironmentKeys` 一致，按序取第一个）：
/// `OPENAI_ADMIN_KEY` → `OPENAI_API_KEY`，去引号去空白。这是 **token** 类 provider，无 cookie 路径。
/// 可选：`OPENAI_ORG_ID` / `OPENAI_ORGANIZATION` → `OpenAI-Organization`，
/// `OPENAI_PROJECT_ID` → `OpenAI-Project`。
///
/// 说明：credit_grants 接口只返回额度总量/已用/余额（$），无周期窗口。这里忠实照搬 CodexBar
/// `OpenAIAPICreditBalanceSnapshot.toUsageSnapshot()` 的判定：
/// total_granted > 0 → usedPercent = total_used/total_granted*100；否则 total_available > 0 → 0%，
/// 不然 100%。因无周期，结果放 `session`，重置时间取 next_grant_expiry（无则 now+30 天），`weekly=nil`。
///
/// 坑（照搬 CodexBar）：该端点可能返回 HTTP 403 —— 需要带账单权限的「legacy/user」API key；
/// project 级 key 通常不暴露 credit grants。Admin key 同样可用于此端点。本机无凭证无法实跑验证。
public enum OpenAIUsageError: LocalizedError, Sendable {
    case missingToken
    case forbidden
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 OpenAI 令牌，请设置环境变量 OPENAI_API_KEY 或 OPENAI_ADMIN_KEY")
        case .forbidden: L("OpenAI 额度接口返回 403：请使用带账单权限的 API key（project 级 key 通常不暴露额度）")
        case let .server(code): L("OpenAI 接口错误（%ld）", code)
        case .invalidResponse: L("OpenAI 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum OpenAIUsageFetcher {
    private static let creditGrantsURL = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!

    /// 是否配置了 OpenAI 令牌（用于在工具面板里把 OpenAI 视作「可用」）。只读环境变量，不发网络。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    /// 与 CodexBar OpenAIAPISettingsReader.apiKeyEnvironmentKeys 一致：OPENAI_ADMIN_KEY → OPENAI_API_KEY。
    static func token(env: [String: String]) -> String? {
        for key in ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"] {
            if let v = clean(env[key]) { return v }
        }
        return nil
    }

    static func organizationID(env: [String: String]) -> String? {
        for key in ["OPENAI_ORG_ID", "OPENAI_ORGANIZATION"] {
            if let v = clean(env[key]) { return v }
        }
        return nil
    }

    static func projectID(env: [String: String]) -> String? {
        clean(env["OPENAI_PROJECT_ID"])
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
        guard let apiKey = token(env: env) else { throw OpenAIUsageError.missingToken }

        var request = URLRequest(url: creditGrantsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let organizationID = organizationID(env: env) {
            request.setValue(organizationID, forHTTPHeaderField: "OpenAI-Organization")
        }
        if let projectID = projectID(env: env) {
            request.setValue(projectID, forHTTPHeaderField: "OpenAI-Project")
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw OpenAIUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as OpenAIUsageError {
            throw e
        } catch {
            throw OpenAIUsageError.network(error.localizedDescription)
        }

        guard http.statusCode != 403 else { throw OpenAIUsageError.forbidden }
        guard http.statusCode == 200 else { throw OpenAIUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    private struct CreditGrant: Decodable {
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
        }
    }

    private struct CreditGrantsList: Decodable {
        let data: [CreditGrant]
    }

    private struct CreditGrantsResponse: Decodable {
        let totalGranted: Double
        let totalUsed: Double
        let totalAvailable: Double
        let grants: CreditGrantsList?

        enum CodingKeys: String, CodingKey {
            case totalGranted = "total_granted"
            case totalUsed = "total_used"
            case totalAvailable = "total_available"
            case grants
        }
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded: CreditGrantsResponse
        do {
            decoded = try decoder.decode(CreditGrantsResponse.self, from: data)
        } catch {
            throw OpenAIUsageError.invalidResponse
        }

        // 与 CodexBar OpenAIAPICreditBalanceSnapshot.toUsageSnapshot 一致：
        // total_granted > 0 → used/granted*100；否则 available > 0 → 0%，不然 100%。
        let usedPercent: Double
        if decoded.totalGranted > 0 {
            usedPercent = min(100, max(0, decoded.totalUsed / decoded.totalGranted * 100))
        } else {
            usedPercent = decoded.totalAvailable > 0 ? 0 : 100
        }

        // 下一笔会发生过期的额度（与 CodexBar 一致：取未来最近的 expires_at）。
        let now = Date()
        let nextExpiry = decoded.grants?.data
            .compactMap(\.expiresAt)
            .filter { $0 > now }
            .min()

        // 额度无周期：百分比放 primary，重置取 next_grant_expiry。
        let available = max(0, decoded.totalAvailable)
        let primary = RateWindow(
            title: L("额度"),
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nextExpiry,
            resetDescription: L("剩余 $%@", String(format: "%.2f", available)))

        // 美元额度补回 providerCost：used=已花、limit=总额度（与 CodexBar
        // OpenAIAPICreditBalanceSnapshot 一致，period="API credits"）。conductor 的
        // ProviderCostSnapshot 无 updatedAt 入参，故省略。
        let providerCost = ProviderCostSnapshot(
            used: max(0, decoded.totalUsed),
            limit: max(0, decoded.totalGranted),
            currencyCode: "USD",
            period: "API credits",
            resetsAt: nextExpiry)

        return UsageSnapshot(
            primary: primary,
            providerCost: providerCost,
            updatedAt: now)
    }
}
