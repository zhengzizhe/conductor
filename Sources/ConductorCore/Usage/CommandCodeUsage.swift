import Foundation
import SweetCookieKit

/// CommandCode（commandcode.ai 订阅）用量取数。忠实移植自 CodexBar `CommandCode` provider
/// （`CommandCodeUsageFetcher.swift` / `CommandCodeUsageSnapshot.swift` / `CommandCodeUsageError.swift`
/// / `CommandCodeCookieHeader.swift` / `CommandCodeCookieImporter.swift` / `CommandCodePlanCatalog.swift`）。
///
/// CommandCode 的 API（`api.commandcode.ai`）用 better-auth 的会话 cookie 鉴权。better-auth 视
/// `useSecureCookies` 而定，cookie 名是 `__Host-better-auth.session_token` /
/// `__Secure-better-auth.session_token` / `better-auth.session_token` 三者之一（生产 HTTPS 多为
/// `__Secure-` 变体）。CodexBar 既支持从浏览器抓 cookie，也支持手动塞一个 `Cookie:` 头或裸 token
/// （`CommandCodeCookieHeader.override(from:)`：裸 token 默认按 `__Secure-better-auth.session_token` 处理）。
///
/// 凭证两条路，token 优先：
///  1. **token（env）**：手动会话令牌——`COMMANDCODE_SESSION_TOKEN` / `COMMANDCODE_COOKIE` /
///     `COMMANDCODE_TOKEN`。可填裸 token（按生产 cookie 名 `__Secure-better-auth.session_token` 包装），
///     也可填整段 `Cookie:` 头（从中抽出受支持的会话 cookie），对应源码 `CommandCodeCookieHeader.override(from:)`。
///  2. **cookie（域名）**：从浏览器抓 `commandcode.ai` 的登录 cookie（用 SweetCookieKit），要求至少含一个
///     受支持的会话 cookie 名（对应源码 `CommandCodeCookieImporter` + `CommandCodeCookieHeader.sessionCookie`）。
///     会触发浏览器 cookie 读取（可能弹钥匙串；Safari 需完全磁盘访问）。
///
/// 取数（源码 `CommandCodeUsageFetcher.fetchUsage`，两请求并发）：
///  - `GET https://api.commandcode.ai/internal/billing/credits` → `credits.monthlyCredits` 等（USD 余额）。
///  - `GET https://api.commandcode.ai/internal/billing/subscriptions` → `data.planId` / `status` /
///    `currentPeriodEnd`。planId 经 `CommandCodePlanCatalog` 映射到套餐月度额度（USD）。
///
/// 解析（源码 `CommandCodeUsageSnapshot`）：套餐月度额度 = 目录里的 `monthlyCreditsUSD`，已用 =
/// `额度 - monthlyCreditsRemaining`（夹到 [0, 额度]）。额度类 → used/limit*100。CommandCode 是
/// 单一月度计费窗口 → 放主窗（会话位），`weekly = nil`（与本仓 Cursor 写法一致）。无周期信息时按本仓
/// 约定：`reset = now + 30 天`。本机无登录态/无令牌时报错，照搬自 CodexBar，无法实跑验证。
public enum CommandCodeUsageError: LocalizedError, Sendable {
    case missingCredentials
    case invalidCredentials
    case server(Int)
    case invalidResponse
    case unknownPlan(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            L("没有找到 CommandCode 登录态，请在浏览器登录 commandcode.ai，或设置环境变量 COMMANDCODE_SESSION_TOKEN")
        case .invalidCredentials:
            L("CommandCode 登录态已失效，请重新登录 commandcode.ai")
        case let .server(code):
            L("CommandCode 接口错误（%ld）", code)
        case .invalidResponse:
            L("CommandCode 用量接口返回异常")
        case let .unknownPlan(planID):
            L("未知的 CommandCode 套餐：%@", planID)
        case let .network(msg):
            L("网络错误：%@", msg)
        }
    }
}

public enum CommandCodeUsageFetcher {
    private static let apiBase = URL(string: "https://api.commandcode.ai")!
    private static let creditsPath = "/internal/billing/credits"
    private static let subscriptionsPath = "/internal/billing/subscriptions"
    private static let webOrigin = "https://commandcode.ai"
    private static let requestTimeout: TimeInterval = 15
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    // CodexBar cookie 域：commandcode.ai / www.commandcode.ai。
    private static let cookieDomains = ["commandcode.ai", "www.commandcode.ai"]
    // CodexBar `CommandCodeCookieHeader.supportedSessionCookieNames`：生产（HTTPS）+ dev（HTTP）。
    private static let supportedSessionCookieNames = [
        "__Host-better-auth.session_token",
        "__Secure-better-auth.session_token",
        "better-auth.session_token",
    ]
    // 裸 token 默认按生产 cookie 名包装（对应 CodexBar `override(from:)` 的裸 token 分支）。
    private static let defaultSessionCookieName = "__Secure-better-auth.session_token"

    // MARK: - 凭证目录（USD 月度额度）

    /// CodexBar `CommandCodePlanCatalog`：planId → 月度额度（USD）。
    private struct Plan {
        let id: String
        let displayName: String
        let monthlyCreditsUSD: Double
    }

    private static let plans: [Plan] = [
        Plan(id: "individual-go", displayName: "Go", monthlyCreditsUSD: 10),
        Plan(id: "individual-pro", displayName: "Pro", monthlyCreditsUSD: 30),
        Plan(id: "individual-max", displayName: "Max", monthlyCreditsUSD: 150),
        Plan(id: "individual-ultra", displayName: "Ultra", monthlyCreditsUSD: 300),
    ]

    private static func plan(forID planID: String) -> Plan? {
        let normalized = planID.lowercased()
        return plans.first { $0.id == normalized }
    }

    // MARK: - 凭证存在性（便宜的本地检查）

    /// 是否配置了 CommandCode 手动会话令牌（token 路；优先）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        tokenCookieHeader(env: env) != nil
    }

    /// 是否能从浏览器拿到 CommandCode 登录 cookie（cookie 路）。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        browserCookieHeader() != nil
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        // token 优先，cookie 兜底（两者皆有取 token）。
        guard let header = tokenCookieHeader(env: env) ?? browserCookieHeader(env: env) else {
            throw CommandCodeUsageError.missingCredentials
        }

        // 与源码一致：credits / subscriptions 两请求并发。
        async let creditsResult = fetchCredits(cookieHeader: header, session: session)
        async let subscriptionResult = fetchSubscription(cookieHeader: header, session: session)
        let credits = try await creditsResult
        let subscription = try await subscriptionResult

        let resolvedPlan: Plan? = subscription.flatMap { Self.plan(forID: $0.planID) }
        // 拿到 active 订阅但 planId 不在目录里 → 显式报错，而非静默丢掉额度行（源码同款）。
        if let sub = subscription, sub.status.lowercased() == "active", resolvedPlan == nil {
            throw CommandCodeUsageError.unknownPlan(sub.planID)
        }

        return makeSnapshot(credits: credits, subscription: subscription, plan: resolvedPlan)
    }

    // MARK: - 凭证解析（token 路）

    /// 从环境变量取手动会话令牌 / Cookie 头，抽出受支持的会话 cookie，拼成 `Cookie:` 头。
    /// 对应 CodexBar `CommandCodeCookieHeader.override(from:)`。
    static func tokenCookieHeader(env: [String: String]) -> String? {
        for key in ["COMMANDCODE_SESSION_TOKEN", "COMMANDCODE_COOKIE", "COMMANDCODE_TOKEN"] {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            // 裸 token（不含 `=` 也不含 `;`）→ 按生产 cookie 名包装。
            if !raw.contains("="), !raw.contains(";") {
                return "\(defaultSessionCookieName)=\(raw)"
            }
            // 否则当作整段 Cookie 头，从中抽出受支持的会话 cookie。
            if let pair = sessionPair(fromHeader: raw) {
                return "\(pair.name)=\(pair.value)"
            }
        }
        if let raw = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "commandcode", env: env) {
            if !raw.contains("="), !raw.contains(";") {
                return "\(defaultSessionCookieName)=\(raw)"
            }
            if let pair = sessionPair(fromHeader: raw) {
                return "\(pair.name)=\(pair.value)"
            }
        }
        return nil
    }

    // MARK: - 凭证解析（cookie 路）

    /// 跨默认浏览器顺序取 commandcode.ai 的 cookie，要求至少含一个受支持的会话 cookie，拼成 Cookie 头。
    static func browserCookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "commandcode", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else {
                continue
            }
            guard cookies.contains(where: { supportedSessionCookieNames.contains($0.name) }) else {
                continue
            }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }

    /// 解析整段 `Cookie:` 头，按受支持名优先级抽出会话 cookie（对应 CodexBar `extractSessionCookie`）。
    private static func sessionPair(fromHeader header: String) -> (name: String, value: String)? {
        var byLowerName: [String: (name: String, value: String)] = [:]
        for chunk in header.split(separator: ";") {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            byLowerName[key.lowercased()] = (name: key, value: value)
        }
        for expected in supportedSessionCookieNames {
            if let match = byLowerName[expected.lowercased()] { return match }
        }
        return nil
    }

    // MARK: - 端点

    private struct CreditsPayload {
        let monthlyCredits: Double
        let purchasedCredits: Double
        let premiumMonthlyCredits: Double
        let opensourceMonthlyCredits: Double
    }

    private struct SubscriptionPayload {
        let planID: String
        let status: String
        let currentPeriodEnd: Date?
    }

    private static func fetchCredits(
        cookieHeader: String,
        session: URLSession) async throws -> CreditsPayload
    {
        let url = apiBase.appendingPathComponent(creditsPath)
        let data = try await send(url: url, cookieHeader: cookieHeader, session: session)
        return try parseCredits(data: data)
    }

    private static func fetchSubscription(
        cookieHeader: String,
        session: URLSession) async throws -> SubscriptionPayload?
    {
        let url = apiBase.appendingPathComponent(subscriptionsPath)
        let data = try await send(url: url, cookieHeader: cookieHeader, session: session)
        return try parseSubscription(data: data)
    }

    private static func send(
        url: URL,
        cookieHeader: String,
        session: URLSession) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(webOrigin, forHTTPHeaderField: "Origin")
        request.setValue("\(webOrigin)/", forHTTPHeaderField: "Referer")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw CommandCodeUsageError.invalidResponse }
            data = d
            http = h
        } catch let error as CommandCodeUsageError {
            throw error
        } catch {
            throw CommandCodeUsageError.network(error.localizedDescription)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw CommandCodeUsageError.invalidCredentials
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CommandCodeUsageError.server(http.statusCode)
        }
        return data
    }

    // MARK: - 解析

    private static func parseCredits(data: Data) throws -> CreditsPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeUsageError.invalidResponse
        }
        guard let credits = root["credits"] as? [String: Any] else {
            throw CommandCodeUsageError.invalidResponse
        }
        guard let monthly = double(from: credits["monthlyCredits"]) else {
            throw CommandCodeUsageError.invalidResponse
        }
        return CreditsPayload(
            monthlyCredits: monthly,
            purchasedCredits: double(from: credits["purchasedCredits"]) ?? 0,
            premiumMonthlyCredits: double(from: credits["premiumMonthlyCredits"]) ?? 0,
            opensourceMonthlyCredits: double(from: credits["opensourceMonthlyCredits"]) ?? 0)
    }

    private static func parseSubscription(data: Data) throws -> SubscriptionPayload? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeUsageError.invalidResponse
        }
        // {"success":true,"data":{...}}；免费档时 data 可能缺失或为 null。
        guard root["success"] as? Bool ?? false else { return nil }
        guard let payload = root["data"] as? [String: Any] else { return nil }
        guard let planID = payload["planId"] as? String, !planID.isEmpty else {
            throw CommandCodeUsageError.invalidResponse
        }
        let status = (payload["status"] as? String) ?? "unknown"
        let periodEnd = date(from: payload["currentPeriodEnd"])
        return SubscriptionPayload(planID: planID, status: status, currentPeriodEnd: periodEnd)
    }

    // MARK: - 映射到 UsageSnapshot

    /// 忠实移植自 CodexBar `CommandCodeUsageSnapshot.toUsageSnapshot()`：
    ///  - 月度额度窗（已用 = 额度 - 余额，clamp [0, 额度]）→ primary（会话位）。
    ///  - CommandCode 是单一月度计费窗口，无 weekly / 第三窗 → secondary / tertiary = nil。
    ///  - `credits.purchasedCredits`（USD top-up 余额）→ providerCost（used=余额、limit=0、"USD"、period "余额"）。
    ///  - 套餐名 → planName。
    private static func makeSnapshot(
        credits: CreditsPayload,
        subscription: SubscriptionPayload?,
        plan: Plan?) -> UsageSnapshot
    {
        let resetAt = subscription?.currentPeriodEnd ?? Date().addingTimeInterval(30 * 24 * 3600)

        // 月度额度窗 → primary。无额度（免费/未知套餐）时按 0% 渲染。
        let primary: RateWindow?
        if let total = plan?.monthlyCreditsUSD, total > 0 {
            // 额度类：已用 = 额度 - 余额（夹到 [0, 额度]）→ used/limit*100。
            let used = max(0, min(total, total - credits.monthlyCredits))
            primary = RateWindow(
                title: L("月度额度 (Monthly)"),
                usedPercent: used / total * 100,
                resetsAt: resetAt)
        } else if credits.monthlyCredits > 0 || credits.purchasedCredits > 0 {
            // 免费 / 未知套餐无额度上限，但尚有余额 → 0% 占位。
            primary = RateWindow(
                title: L("月度额度 (Monthly)"),
                usedPercent: 0,
                resetsAt: resetAt)
        } else {
            primary = nil
        }

        // USD top-up balance（credits）→ providerCost：used=余额、limit=0（无上限，仅显余额）。
        let providerCost: ProviderCostSnapshot? = credits.purchasedCredits > 0
            ? ProviderCostSnapshot(
                used: credits.purchasedCredits,
                limit: 0,
                currencyCode: "USD",
                period: L("余额"))
            : nil

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: providerCost,
            planName: plan?.displayName)
    }

    // MARK: - 取值

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
