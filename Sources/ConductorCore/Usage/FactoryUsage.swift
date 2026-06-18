import Foundation
import SweetCookieKit

/// Factory（factory.ai / droid）用量取数。忠实转写 CodexBar `Factory` provider 的 cookie 路径
/// （用 SweetCookieKit）：从浏览器里取 factory.ai 域的登录 cookie → 调 Factory 私有接口
/// （`/api/app/auth/me` 取身份，`/api/organization/subscription/usage` 取 Standard/Premium token 用量；
/// 若账号开启了新的 token-rate-limits 计费，则改读 `api.factory.ai/api/billing/limits`）→ 拼成会话/周快照。
///
/// 凭证来源：浏览器 cookie（域名 `factory.ai` / `app.factory.ai` / `auth.factory.ai`）。CodexBar 里 Factory
/// 没有「环境变量 API key」入口；但 cookie 里的 `access-token`（当其为 JWT，含 `.`）会被当作 Bearer 令牌随请求发出，
/// 即「两者皆有时优先 token（Bearer）」。本实现只做 cookie 自动导入这一条主路径（不含手动 cookie/WorkOS 刷新等回退）。
///
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 无登录态 / 无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum FactoryUsageError: LocalizedError, Sendable {
    case noSession
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 Factory 登录态，请在浏览器登录 app.factory.ai（Safari 需开启完全磁盘访问）")
        case .unauthorized: L("Factory 登录态已失效，请重新登录 app.factory.ai")
        case let .server(c): L("Factory 接口错误（%ld）", c)
        case .invalidResponse: L("Factory 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum FactoryUsageFetcher {
    // Factory cookie 所在域；与 CodexBar FactoryCookieImporter 一致。
    private static let cookieDomains = ["factory.ai", "app.factory.ai", "auth.factory.ai"]
    // 已知会话 cookie 名（摘自 CodexBar FactoryCookieImporter.sessionCookieNames）。
    private static let sessionCookieNames: Set<String> = [
        "wos-session",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "__Host-authjs.csrf-token",
        "authjs.session-token",
        "session",
        "access-token",
    ]
    // 可作为 Bearer 来源的「会话型」cookie 名（摘自 CodexBar authSessionCookieNames）。
    private static let authSessionCookieNames: Set<String> = [
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "authjs.session-token",
    ]

    private static let appBaseURL = URL(string: "https://app.factory.ai")!
    private static let authBaseURL = URL(string: "https://auth.factory.ai")!
    private static let apiBaseURL = URL(string: "https://api.factory.ai")!

    /// 是否能从浏览器拿到 Factory 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        UsageProviderRuntimeConfig.manualCookieHeader(providerID: "factory", env: env) != nil
            || cookies(env: env) != nil
    }

    /// 跨默认浏览器顺序取 factory.ai 域的 cookie；要求至少含一个已知会话 cookie。
    static func cookies(env: [String: String] = ProcessInfo.processInfo.environment) -> [HTTPCookie]? {
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "factory", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        var fallback: [HTTPCookie]?
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            if cookies.contains(where: { sessionCookieNames.contains($0.name) }) {
                return cookies
            }
            if fallback == nil { fallback = cookies }
        }
        // 兜底：任意浏览器的 factory 域 cookie（让 API 去校验）。
        return fallback
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) async throws -> UsageSnapshot {
        if let manualHeader = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "factory", env: env) {
            return try await fetchUsingCandidates(
                cookieHeader: manualHeader,
                bearerToken: bearerToken(fromCookieHeader: manualHeader),
                candidates: [apiBaseURL, appBaseURL, authBaseURL],
                session: session)
        }

        guard let cookies = cookies(env: env) else { throw FactoryUsageError.noSession }
        let header = cookieHeader(from: cookies)
        let bearer = bearerToken(from: cookies)

        // CodexBar 按 cookie 域优先尝试不同 base URL；这里照搬其候选顺序。
        return try await fetchUsingCandidates(
            cookieHeader: header,
            bearerToken: bearer,
            candidates: baseURLCandidates(cookies: cookies),
            session: session)
    }

    private static func fetchUsingCandidates(
        cookieHeader: String,
        bearerToken: String?,
        candidates: [URL],
        session: URLSession
    ) async throws -> UsageSnapshot {
        var lastError: Error?
        for baseURL in candidates {
            do {
                return try await fetch(
                    cookieHeader: cookieHeader,
                    bearerToken: bearerToken,
                    baseURL: baseURL,
                    session: session)
            } catch let e as FactoryUsageError {
                lastError = e
            }
        }
        throw lastError ?? FactoryUsageError.noSession
    }

    // MARK: - 单 base URL 拉取

    private static func fetch(
        cookieHeader: String,
        bearerToken: String?,
        baseURL: URL,
        session: URLSession) async throws -> UsageSnapshot
    {
        // 先取身份（plan / tier），顺带验证登录态。
        let auth = try await fetchAuth(
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            baseURL: baseURL,
            session: session)
        let userId = factoryNormalizedString(auth.userProfile?.id)
            ?? factoryUserIdFromBearerToken(bearerToken)
        let planType = loginMethod(tier: auth.organization?.subscription?.factoryTier,
                                   planName: auth.organization?.subscription?.orbSubscription?.plan?.name)
        let accountLabel = factoryNormalizedString(auth.organization?.name)

        // 新计费（token-rate-limits）账号：改读 api.factory.ai/api/billing/limits。
        if let limits = try? await fetchBillingLimits(
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            session: session),
            limits.usesTokenRateLimitsBilling,
            let rate = limits.limits
        {
            return tokenRateLimitsSnapshot(
                planType: planType,
                accountLabel: accountLabel,
                overagePreference: limits.overagePreference,
                extraUsageBalanceCents: limits.extraUsageBalanceCents,
                limits: rate)
        }

        // 旧计费：Standard / Premium token 用量。
        let usage = try await fetchUsage(
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            userId: userId,
            baseURL: baseURL,
            session: session)
        return usageSnapshot(planType: planType, accountLabel: accountLabel, usage: usage.usage)
    }

    // MARK: - 请求构造

    private static func makeRequest(
        url: URL,
        cookieHeader: String,
        bearerToken: String?) -> URLRequest
    {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func send(
        _ request: URLRequest,
        session: URLSession) async throws -> (Data, HTTPURLResponse)
    {
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw FactoryUsageError.invalidResponse }
            return (d, h)
        } catch let e as FactoryUsageError {
            throw e
        } catch {
            throw FactoryUsageError.network(error.localizedDescription)
        }
    }

    private static func fetchAuth(
        cookieHeader: String,
        bearerToken: String?,
        baseURL: URL,
        session: URLSession) async throws -> FactoryAuthResponse
    {
        let url = baseURL.appendingPathComponent("/api/app/auth/me")
        let (data, http) = try await send(
            makeRequest(url: url, cookieHeader: cookieHeader, bearerToken: bearerToken),
            session: session)
        if http.statusCode == 401 || http.statusCode == 403 { throw FactoryUsageError.unauthorized }
        guard http.statusCode == 200 else { throw FactoryUsageError.server(http.statusCode) }
        do {
            return try JSONDecoder().decode(FactoryAuthResponse.self, from: data)
        } catch {
            throw FactoryUsageError.invalidResponse
        }
    }

    private static func fetchUsage(
        cookieHeader: String,
        bearerToken: String?,
        userId: String?,
        baseURL: URL,
        session: URLSession) async throws -> FactoryUsageResponse
    {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/organization/subscription/usage"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "useCache", value: "true")]
        if let userId {
            components?.queryItems?.append(URLQueryItem(name: "userId", value: userId))
        }
        let url = components?.url ?? baseURL.appendingPathComponent("/api/organization/subscription/usage")
        let (data, http) = try await send(
            makeRequest(url: url, cookieHeader: cookieHeader, bearerToken: bearerToken),
            session: session)
        if http.statusCode == 401 || http.statusCode == 403 { throw FactoryUsageError.unauthorized }
        guard http.statusCode == 200 else { throw FactoryUsageError.server(http.statusCode) }
        do {
            return try JSONDecoder().decode(FactoryUsageResponse.self, from: data)
        } catch {
            throw FactoryUsageError.invalidResponse
        }
    }

    private static func fetchBillingLimits(
        cookieHeader: String,
        bearerToken: String?,
        session: URLSession) async throws -> FactoryBillingLimitsResponse?
    {
        let url = apiBaseURL.appendingPathComponent("/api/billing/limits")
        let (data, http) = try await send(
            makeRequest(url: url, cookieHeader: cookieHeader, bearerToken: bearerToken),
            session: session)
        guard http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(FactoryBillingLimitsResponse.self, from: data)
    }

    // MARK: - cookie / bearer 处理

    private static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 从 cookie 推断 Bearer 令牌：优先含 `.` 的 JWT（access-token > 会话 token > legacy session）。
    /// 摘自 CodexBar FactoryStatusProbe.bearerToken(from:)。
    private static func bearerToken(from cookies: [HTTPCookie]) -> String? {
        let accessToken = cookies.first(where: { $0.name == "access-token" })?.value
        let sessionToken = cookies.first(where: { authSessionCookieNames.contains($0.name) })?.value
        let legacySession = cookies.first(where: { $0.name == "session" })?.value

        if let accessToken, accessToken.contains(".") { return accessToken }
        if let sessionToken, sessionToken.contains(".") { return sessionToken }
        if let legacySession, legacySession.contains(".") { return legacySession }
        return accessToken ?? sessionToken
    }

    private static func bearerToken(fromCookieHeader header: String) -> String? {
        let cookies = cookiePairs(fromHeader: header)
        let accessToken = cookies["access-token"]
        let sessionToken = authSessionCookieNames.compactMap { cookies[$0] }.first
        let legacySession = cookies["session"]

        if let accessToken, accessToken.contains(".") { return accessToken }
        if let sessionToken, sessionToken.contains(".") { return sessionToken }
        if let legacySession, legacySession.contains(".") { return legacySession }
        return accessToken ?? sessionToken
    }

    private static func cookiePairs(fromHeader header: String) -> [String: String] {
        var result: [String: String] = [:]
        for chunk in header.split(separator: ";") {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    /// CodexBar baseURLCandidates：cookie 含 auth 域则先试 auth，再 api、app，最后默认 app。
    private static func baseURLCandidates(cookies: [HTTPCookie]) -> [URL] {
        let domains = Set(cookies.map { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        var candidates: [URL] = []
        if domains.contains("auth.factory.ai") { candidates.append(authBaseURL) }
        candidates.append(apiBaseURL)
        candidates.append(appBaseURL)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func factoryUserIdFromBearerToken(_ token: String?) -> String? {
        guard let token, let claims = parseJWT(token), let sub = claims["sub"] as? String else { return nil }
        return factoryNormalizedString(sub)
    }

    private static func factoryNormalizedString(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    /// 解析 JWT payload（无验签，仅取 claims）。base64url → JSON。
    private static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - 身份格式化

    /// CodexBar：tier + plan 拼成 “Factory Pro - <plan>”。
    private static func loginMethod(tier: String?, planName: String?) -> String? {
        var parts: [String] = []
        if let tier, !tier.isEmpty { parts.append("Factory \(tier.capitalized)") }
        if let planName, !planName.isEmpty, !planName.lowercased().contains("factory") { parts.append(planName) }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    // MARK: - 快照构造

    /// 旧计费：Standard → 主窗（primary），Premium → 次窗（secondary）。
    /// 额度 → used/limit*100；优先 API 的 usedRatio。无窗口周期 → reset = endDate。
    static func usageSnapshot(
        planType: String?,
        accountLabel: String?,
        usage: FactoryUsageData?) -> UsageSnapshot
    {
        let periodEnd = usage?.endDate.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }

        func window(_ pool: FactoryTokenUsage?, title: String) -> RateWindow? {
            guard let pool else { return nil }
            let percent = usagePercent(
                used: pool.userTokens ?? 0,
                allowance: pool.totalAllowance ?? 0,
                apiRatio: pool.usedRatio)
            return RateWindow(
                title: title,
                usedPercent: percent,
                resetsAt: periodEnd)
        }

        let primary = window(usage?.standard, title: L("标准 Standard"))
        let secondary = window(usage?.premium, title: L("高级 Premium"))
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            planName: planType,
            accountLabel: accountLabel)
    }

    /// 新计费（token-rate-limits）：standard.fiveHour → 主窗（5h），standard.weekly → 次窗（7d），
    /// standard.monthly → 第三窗（Monthly）；core 池有数据时进 extraRateWindows；
    /// extraUsageBalanceCents → providerCost（额外用量余额，无上限）。
    static func tokenRateLimitsSnapshot(
        planType: String?,
        accountLabel: String?,
        overagePreference: String?,
        extraUsageBalanceCents: Int,
        limits: FactoryTokenRateLimits) -> UsageSnapshot
    {
        let now = Date()
        func window(_ w: FactoryBillingWindow, title: String, windowMinutes: Int?) -> RateWindow {
            RateWindow(
                title: title,
                usedPercent: w.effectiveUsedPercent(now: now),
                windowMinutes: windowMinutes,
                resetsAt: w.resetAt(now: now))
        }

        let primary = window(limits.standard.fiveHour, title: L("5 小时"), windowMinutes: 5 * 60)
        let secondary = window(limits.standard.weekly, title: L("本周 7-day"), windowMinutes: 7 * 24 * 60)
        let tertiary = window(limits.standard.monthly, title: L("本月 Monthly"), windowMinutes: nil)

        var extraWindows: [NamedRateWindow] = []
        if let core = limits.core, core.hasUsageData {
            extraWindows = [
                NamedRateWindow(
                    id: "factory-core-5h",
                    title: L("Core 5 小时"),
                    window: window(core.fiveHour, title: L("Core 5 小时"), windowMinutes: 5 * 60)),
                NamedRateWindow(
                    id: "factory-core-7d",
                    title: L("Core 7-day"),
                    window: window(core.weekly, title: L("Core 7-day"), windowMinutes: 7 * 24 * 60)),
                NamedRateWindow(
                    id: "factory-core-monthly",
                    title: L("Core Monthly"),
                    window: window(core.monthly, title: L("Core Monthly"), windowMinutes: nil)),
            ]
        }

        // 旧实现把余额塞进 planType；现按要求改为 providerCost（$，无上限）。
        let providerCost: ProviderCostSnapshot? = ProviderCostSnapshot(
            used: Double(extraUsageBalanceCents) / 100.0,
            limit: 0,
            currencyCode: "USD",
            period: L("额外用量余额"))

        // CodexBar 会把 overagePreference 拼进 loginMethod；这里并入 planName。
        let planName: String? = {
            var parts: [String] = []
            if let planType, !planType.isEmpty { parts.append(planType) }
            if let overagePreference, !overagePreference.isEmpty {
                parts.append(L("超额回退：%@", overagePreference))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " - ")
        }()

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraWindows,
            providerCost: providerCost,
            planName: planName,
            accountLabel: accountLabel)
    }

    /// CodexBar calculateUsagePercent：优先 API ratio（0–1 或缺额度时的 0–100），否则 used/allowance；
    /// 超 1 万亿额度按「无限」处理（以 1 亿 token 为 100% 参照）。
    private static func usagePercent(used: Int64, allowance: Int64, apiRatio: Double?) -> Double {
        let unlimitedThreshold: Int64 = 1_000_000_000_000
        if let ratio = apiRatio,
           !(ratio == 0 && used > 0 && allowance > 0 && allowance <= unlimitedThreshold),
           let percent = percentFromAPIRatio(ratio, allowance: allowance, unlimitedThreshold: unlimitedThreshold)
        {
            return percent
        }
        if allowance > unlimitedThreshold {
            let referenceTokens: Double = 100_000_000
            return min(100, Double(used) / referenceTokens * 100)
        }
        guard allowance > 0 else { return 0 }
        return min(100, Double(used) / Double(allowance) * 100)
    }

    private static func percentFromAPIRatio(
        _ ratio: Double,
        allowance: Int64,
        unlimitedThreshold: Int64) -> Double?
    {
        guard ratio.isFinite else { return nil }
        if ratio >= -0.001, ratio <= 1.001 {
            return min(100, max(0, ratio * 100))
        }
        let allowanceIsReliable = allowance > 0 && allowance <= unlimitedThreshold
        if !allowanceIsReliable, ratio >= -0.1, ratio <= 100.1 {
            return min(100, max(0, ratio))
        }
        return nil
    }
}

// MARK: - Factory API 模型（摘自 CodexBar，按本实现所需裁剪）

private struct FactoryAuthResponse: Decodable {
    let organization: FactoryOrganization?
    let userProfile: FactoryUserProfile?
}

private struct FactoryUserProfile: Decodable {
    let id: String?
    let email: String?
}

private struct FactoryOrganization: Decodable {
    let id: String?
    let name: String?
    let subscription: FactorySubscription?
}

private struct FactorySubscription: Decodable {
    let factoryTier: String?
    let orbSubscription: FactoryOrbSubscription?
}

private struct FactoryOrbSubscription: Decodable {
    let plan: FactoryPlan?
    let status: String?
}

private struct FactoryPlan: Decodable {
    let name: String?
    let id: String?
}

private struct FactoryUsageResponse: Decodable {
    let usage: FactoryUsageData?
    let source: String?
    let userId: String?
}

struct FactoryUsageData: Decodable {
    let startDate: Int64?
    let endDate: Int64?
    let standard: FactoryTokenUsage?
    let premium: FactoryTokenUsage?
}

struct FactoryTokenUsage: Decodable {
    let userTokens: Int64?
    let orgTotalTokensUsed: Int64?
    let totalAllowance: Int64?
    let usedRatio: Double?
    let orgOverageUsed: Int64?
    let basicAllowance: Int64?
    let orgOverageLimit: Int64?
}

private struct FactoryBillingLimitsResponse: Decodable {
    let usesTokenRateLimitsBilling: Bool
    let limits: FactoryTokenRateLimits?
    let extraUsageBalanceCents: Int
    let overagePreference: String?
    let extraUsageAllowed: Bool
    let tokenRateLimitsRolloutEligible: Bool

    enum CodingKeys: String, CodingKey {
        case usesTokenRateLimitsBilling
        case limits
        case extraUsageBalanceCents
        case overagePreference
        case extraUsageAllowed
        case tokenRateLimitsRolloutEligible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usesTokenRateLimitsBilling = try container
            .decodeIfPresent(Bool.self, forKey: .usesTokenRateLimitsBilling) ?? false
        self.limits = try container.decodeIfPresent(FactoryTokenRateLimits.self, forKey: .limits)
        self.extraUsageBalanceCents = try container.decodeIfPresent(Int.self, forKey: .extraUsageBalanceCents) ?? 0
        self.overagePreference = try container.decodeIfPresent(String.self, forKey: .overagePreference)
        self.extraUsageAllowed = try container.decodeIfPresent(Bool.self, forKey: .extraUsageAllowed) ?? false
        self.tokenRateLimitsRolloutEligible = try container
            .decodeIfPresent(Bool.self, forKey: .tokenRateLimitsRolloutEligible) ?? false
    }
}

struct FactoryTokenRateLimits: Decodable {
    let standard: FactoryLimitPool
    let core: FactoryLimitPool?
}

struct FactoryLimitPool: Decodable {
    let fiveHour: FactoryBillingWindow
    let weekly: FactoryBillingWindow
    let monthly: FactoryBillingWindow

    /// 是否有可展示的用量（任一窗有 used%/窗口端点/剩余秒）。摘自 CodexBar FactoryLimitPool。
    var hasUsageData: Bool {
        [self.fiveHour, self.weekly, self.monthly].contains {
            $0.usedPercent > 0 || $0.windowEnd != nil || $0.secondsRemaining != nil
        }
    }
}

struct FactoryBillingWindow: Decodable {
    let usedPercent: Double
    let windowEnd: FlexibleFactoryDate?
    let secondsRemaining: Double?

    func resetAt(now: Date) -> Date? {
        if let secondsRemaining, secondsRemaining > 0 {
            return now.addingTimeInterval(secondsRemaining)
        }
        guard let windowEnd = self.windowEnd?.date, windowEnd > now else { return nil }
        return windowEnd
    }

    /// Factory 在短滚动窗口过期后会留下陈旧值；Web UI 把这种状态当作已重置（归零），这里照搬。
    func effectiveUsedPercent(now: Date) -> Double {
        if self.resetAt(now: now) == nil, self.windowEnd != nil, self.secondsRemaining == nil {
            return 0
        }
        return min(100, max(0, self.usedPercent))
    }
}

struct FlexibleFactoryDate: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            self.date = Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000.0 : seconds)
            return
        }
        let string = try container.decode(String.self)
        if let numeric = Double(string) {
            self.date = Date(timeIntervalSince1970: numeric > 1e12 ? numeric / 1000.0 : numeric)
            return
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
            self.date = parsed
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Factory date")
    }
}
