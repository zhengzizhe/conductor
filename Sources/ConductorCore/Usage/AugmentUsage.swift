import Foundation
import SweetCookieKit

/// Augment（auggie）用量取数。摘自 CodexBar `Augment` provider 的浏览器 cookie 路径(用 SweetCookieKit):
/// 从浏览器里取 augmentcode.com 的登录 cookie → `GET app.augmentcode.com/api/credits`（必需）拿额度，
/// 再 `GET /api/subscription`（可选，给套餐名/计费周期结束日）→ 算已用百分比。
///
/// Augment 在 CodexBar 里是 **cookie 类** provider（无 env token；Auth0/NextAuth/AuthJS 会话 cookie）。
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 无登录态/无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum AugmentUsageError: LocalizedError, Sendable {
    case noSession
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 Augment 登录态，请在浏览器登录 app.augmentcode.com（Safari 需开启完全磁盘访问）")
        case .unauthorized: L("Augment 登录态已失效，请重新登录 app.augmentcode.com")
        case let .server(c): L("Augment 接口错误（%ld）", c)
        case .invalidResponse: L("Augment 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum AugmentUsageFetcher {
    private static let cookieDomains = ["augmentcode.com", "app.augmentcode.com"]
    /// Auth0 / NextAuth / AuthJS 会话 cookie 名（照搬自 CodexBar AugmentCookieImporter）。
    private static let sessionCookieNames: Set<String> = [
        "session", // Augment auth session (auth.augmentcode.com)
        "_session", // Legacy session cookie (app.augmentcode.com)
        "web_rpc_proxy_session", // Augment RPC proxy session
        "auth0", // Auth0 session
        "auth0.is.authenticated", // Auth0 authentication flag
        "a0.spajs.txs", // Auth0 SPA transaction state
        "__Secure-next-auth.session-token", // NextAuth secure session
        "next-auth.session-token", // NextAuth session
        "__Secure-authjs.session-token", // AuthJS secure session
        "__Host-authjs.csrf-token", // AuthJS CSRF token
        "authjs.session-token", // AuthJS session
    ]

    /// 是否能从浏览器拿到 Augment 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 augmentcode.com 的 cookie，拼成 Cookie 头；要求至少含一个已知会话 cookie。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "augment", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "augment", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            let hasNamed = cookies.contains { sessionCookieNames.contains($0.name) }
            // 优先返回含已知会话名的那组；否则也返回（让 API 去校验）。
            if hasNamed || browser == Browser.defaultImportOrder.last {
                return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        // 兜底：任意浏览器的 augment 域 cookie。
        for browser in Browser.defaultImportOrder {
            if let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty {
                return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        return nil
    }

    public static func fetch(session: URLSession = .shared) async throws -> CodexUsageSnapshot {
        guard let header = cookieHeader() else { throw AugmentUsageError.noSession }

        // 额度（必需）。
        let credits = try await fetchCredits(cookieHeader: header, session: session)
        // 订阅（可选）：拿套餐名/计费周期结束日；失败不影响主流程。
        let subscription = try? await fetchSubscription(cookieHeader: header, session: session)

        return parse(credits: credits, subscription: subscription)
    }

    // MARK: - 请求

    private static func fetchCredits(cookieHeader: String, session: URLSession) async throws -> CreditsResponse {
        let url = URL(string: "https://app.augmentcode.com/api/credits")!
        let data = try await get(url, cookieHeader: cookieHeader, session: session)
        do { return try JSONDecoder().decode(CreditsResponse.self, from: data) }
        catch { throw AugmentUsageError.invalidResponse }
    }

    private static func fetchSubscription(
        cookieHeader: String,
        session: URLSession) async throws -> SubscriptionResponse
    {
        let url = URL(string: "https://app.augmentcode.com/api/subscription")!
        let data = try await get(url, cookieHeader: cookieHeader, session: session)
        do { return try JSONDecoder().decode(SubscriptionResponse.self, from: data) }
        catch { throw AugmentUsageError.invalidResponse }
    }

    private static func get(_ url: URL, cookieHeader: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw AugmentUsageError.invalidResponse }
            data = d; http = h
        } catch let e as AugmentUsageError {
            throw e
        } catch {
            throw AugmentUsageError.network(error.localizedDescription)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw AugmentUsageError.unauthorized }
        guard http.statusCode == 200 else { throw AugmentUsageError.server(http.statusCode) }
        return data
    }

    // MARK: - 解析

    private struct CreditsResponse: Decodable {
        let usageUnitsRemaining: Double?
        let usageUnitsConsumedThisBillingCycle: Double?
        let usageUnitsAvailable: Double?
        let usageBalanceStatus: String?

        var creditsRemaining: Double? { usageUnitsRemaining }
        var creditsUsed: Double? { usageUnitsConsumedThisBillingCycle }
        var creditsLimit: Double? {
            if let available = usageUnitsAvailable, available > 0 { return available }
            guard let remaining = usageUnitsRemaining,
                  let consumed = usageUnitsConsumedThisBillingCycle
            else { return nil }
            return remaining + consumed
        }
    }

    private struct SubscriptionResponse: Decodable {
        let planName: String?
        let billingPeriodEnd: String?
        let email: String?
        let organization: String?
    }

    private static func parse(credits: CreditsResponse, subscription: SubscriptionResponse?) -> CodexUsageSnapshot {
        let used = credits.creditsUsed
        let limit = credits.creditsLimit
        let remaining = credits.creditsRemaining

        // 已用百分比：优先 used/limit；否则 (limit-remaining)/limit。
        let percent: Double = if let used, let limit, limit > 0 {
            max(0, min(100, used / limit * 100))
        } else if let remaining, let limit, limit > 0 {
            max(0, min(100, (limit - remaining) / limit * 100))
        } else {
            0
        }

        // 计费周期结束日（ISO8601）。无则窗口 = now + 30 天。
        let end = parseISO(subscription?.billingPeriodEnd)
        let resetAt = end ?? Date().addingTimeInterval(30 * 24 * 3600)
        let windowSeconds = max(1, Int(resetAt.timeIntervalSinceNow))

        // Augment 是单一计费周期额度 → 放主窗（会话位）；无周窗。
        let window = CodexUsageSnapshot.Window(
            usedPercent: Int(percent.rounded()),
            resetAt: resetAt,
            windowSeconds: windowSeconds)
        return CodexUsageSnapshot(planType: subscription?.planName, session: window, weekly: nil)
    }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
