import Foundation
import SweetCookieKit

/// Perplexity 用量取数。忠实摘自 CodexBar `Perplexity` provider：
/// 凭一个 Perplexity 会话 cookie（session-token）调
/// `GET https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default`，
/// 解析 `credit_grants`（recurring / promotional / purchased）与 `total_usage_cents`，
/// 用「瀑布」归因（recurring → purchased → promotional）算出各池已用额度。
///
/// 会话凭证两条来源，优先 env：
///   1) 环境变量：`PERPLEXITY_SESSION_TOKEN`（裸 token）或 `PERPLEXITY_COOKIE`（完整 Cookie 头）。
///   2) 浏览器 cookie：跨默认浏览器顺序读 perplexity.ai 域，提取受支持的 session-token cookie。
/// 两者都拼成 `Cookie: <name>=<token>` 头发出。
///
/// 该接口只给「额度池」（美分），没有任何时间窗/重置周期字段——renewal_date_ts 是套餐续费日。
/// 因此映射为单一 session 窗：usedPercent = recurringUsed/recurringTotal*100；
/// 无可用周期信息，session.resetAt = now + 30 天、windowSeconds = 30 天、weekly = nil。
/// planType 由 recurring 额度推断（0→nil，<5000→Pro，否则 Max），与 CodexBar 一致。
///
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 照搬自 CodexBar，本机无登录态无法实跑验证。
public enum PerplexityUsageError: LocalizedError, Sendable {
    case noSession
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 Perplexity 登录态，请设置 PERPLEXITY_SESSION_TOKEN 或在浏览器登录 perplexity.ai（Safari 需开启完全磁盘访问）")
        case .unauthorized: L("Perplexity 登录态已失效或无效，请重新登录 perplexity.ai")
        case let .server(c): L("Perplexity 接口错误（%ld）", c)
        case .invalidResponse: L("Perplexity 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum PerplexityUsageFetcher {
    private static let creditsURL =
        URL(string: "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default")!
    // 照搬 CodexBar：www.perplexity.ai / perplexity.ai 两域。
    private static let cookieDomains = ["www.perplexity.ai", "perplexity.ai"]
    // 受支持的会话 cookie 名（按优先级；默认用第一个发请求）。照搬 CodexBar supportedSessionCookieNames。
    private static let sessionCookieNames = [
        "__Secure-authjs.session-token",
        "authjs.session-token",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
    ]
    private static let defaultSessionCookieName = "__Secure-next-auth.session-token"

    /// 单条已解析会话凭证：cookie 名 + token 值。
    struct SessionCookie {
        let name: String
        let token: String
    }

    /// 是否存在 Perplexity 会话凭证（env 或浏览器 cookie）。
    /// 注意：无 env 时会触发一次浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        resolveSessionCookie(env: env) != nil
    }

    /// 解析会话凭证。优先 env（裸 token 或完整 Cookie 头），其次浏览器 cookie。
    static func resolveSessionCookie(env: [String: String]) -> SessionCookie? {
        if let fromEnv = sessionCookieFromEnv(env: env) { return fromEnv }
        return sessionCookieFromBrowser(env: env)
    }

    // MARK: - env 来源

    /// `PERPLEXITY_SESSION_TOKEN`（裸 token）或 `PERPLEXITY_COOKIE`（完整 Cookie 头）。
    static func sessionCookieFromEnv(env: [String: String]) -> SessionCookie? {
        if let token = clean(env["PERPLEXITY_SESSION_TOKEN"] ?? env["perplexity_session_token"]) {
            return cookie(fromRaw: token)
        }
        if let cookieRaw = clean(env["PERPLEXITY_COOKIE"]) {
            return cookie(fromRaw: cookieRaw)
        }
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "perplexity", env: env) {
            return cookie(fromRaw: manual)
        }
        return nil
    }

    /// 裸 token → 用默认 cookie 名；完整 Cookie 头 → 抽取受支持的 session cookie。照搬 CodexBar override(from:)。
    static func cookie(fromRaw raw: String) -> SessionCookie? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 裸 token 值（不含 `=` 和 `;`）。
        if !trimmed.contains("="), !trimmed.contains(";") {
            return SessionCookie(name: defaultSessionCookieName, token: trimmed)
        }
        // 完整 Cookie 头：拆成 name=value 对，抽取受支持的 session cookie。
        var pairs: [(name: String, value: String)] = []
        for part in trimmed.split(separator: ";") {
            let seg = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let key = String(seg[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(seg[seg.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            pairs.append((name: key, value: value))
        }
        return extractSessionCookie(from: pairs)
    }

    // MARK: - 浏览器 cookie 来源

    /// 跨默认浏览器顺序读 perplexity 域 cookie，抽取受支持的 session-token cookie。照搬 CodexBar CookieImporter。
    static func sessionCookieFromBrowser(env: [String: String] = ProcessInfo.processInfo.environment) -> SessionCookie? {
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "perplexity", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            let pairs = cookies.map { (name: $0.name, value: $0.value) }
            if let session = extractSessionCookie(from: pairs) { return session }
        }
        return nil
    }

    /// 从 name=value 对里按优先级抽取受支持的 session cookie（大小写不敏感）。
    private static func extractSessionCookie(from cookies: [(name: String, value: String)]) -> SessionCookie? {
        var map: [String: (name: String, value: String)] = [:]
        for cookie in cookies where !cookie.value.isEmpty {
            map[cookie.name.lowercased()] = cookie
        }
        for expected in sessionCookieNames {
            if let match = map[expected.lowercased()] {
                return SessionCookie(name: match.name, token: match.value)
            }
        }
        return nil
    }

    private static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let cookie = resolveSessionCookie(env: env) else { throw PerplexityUsageError.noSession }

        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(cookie.name)=\(cookie.token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.perplexity.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://www.perplexity.ai/account/usage", forHTTPHeaderField: "Referer")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw PerplexityUsageError.invalidResponse }
            data = d; http = h
        } catch let e as PerplexityUsageError {
            throw e
        } catch {
            throw PerplexityUsageError.network(error.localizedDescription)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw PerplexityUsageError.unauthorized }
        guard http.statusCode == 200 else { throw PerplexityUsageError.server(http.statusCode) }
        return try parse(data, now: Date())
    }

    // MARK: - 解析

    private struct CreditsResponse: Decodable {
        let balanceCents: Double
        let renewalDateTs: TimeInterval
        let currentPeriodPurchasedCents: Double
        let creditGrants: [CreditGrant]
        let totalUsageCents: Double

        enum CodingKeys: String, CodingKey {
            case balanceCents = "balance_cents"
            case renewalDateTs = "renewal_date_ts"
            case currentPeriodPurchasedCents = "current_period_purchased_cents"
            case creditGrants = "credit_grants"
            case totalUsageCents = "total_usage_cents"
        }
    }

    private struct CreditGrant: Decodable {
        let type: String
        let amountCents: Double
        let expiresAtTs: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case type
            case amountCents = "amount_cents"
            case expiresAtTs = "expires_at_ts"
        }
    }

    static func parse(_ data: Data, now: Date) throws -> UsageSnapshot {
        let response: CreditsResponse
        do { response = try JSONDecoder().decode(CreditsResponse.self, from: data) }
        catch { throw PerplexityUsageError.invalidResponse }

        // —— 照搬 CodexBar PerplexityUsageSnapshot 的归因逻辑 ——
        // 时间戳均为 Unix 秒。promotional 仅计未过期的。credits 单位为 cents（1 credit = 1 cent，
        // 与 CodexBar 一致，展示时直接当 credits 数量）。
        let recurring = response.creditGrants.filter { $0.type == "recurring" }
        let promotional = response.creditGrants.filter {
            $0.type == "promotional" && ($0.expiresAtTs ?? .infinity) > now.timeIntervalSince1970
        }
        let purchased = response.creditGrants.filter { $0.type == "purchased" }

        let recurringSum = max(0, recurring.reduce(0.0) { $0 + $1.amountCents })
        // purchased 可能出现在 grants 数组或顶层字段（或两者），取较大者避免重复计数。
        let purchasedFromGrants = max(0, purchased.reduce(0.0) { $0 + $1.amountCents })
        let purchasedFromField = max(0, response.currentPeriodPurchasedCents)
        let purchasedSum = max(purchasedFromGrants, purchasedFromField)
        let promoSum = max(0, promotional.reduce(0.0) { $0 + $1.amountCents })

        // 瀑布归因：recurring → purchased → promotional。
        var remaining = response.totalUsageCents
        let usedFromRecurring = min(remaining, recurringSum); remaining -= usedFromRecurring
        let usedFromPurchased = min(remaining, purchasedSum); remaining -= usedFromPurchased
        let usedFromPromo = min(remaining, promoSum)

        let renewalDate = Date(timeIntervalSince1970: response.renewalDateTs)
        let promoExpiration = promotional
            .compactMap { $0.expiresAtTs.map { Date(timeIntervalSince1970: $0) } }
            .min()

        // 套餐名推断：recurring 额度 0→nil，<5000→Pro，否则 Max（照搬 CodexBar planName）。
        let planName: String? = {
            if recurringSum <= 0 { return nil }
            if recurringSum < 5000 { return "Pro" }
            return "Max"
        }()

        // —— 映射到富 UsageSnapshot（三个 credits 池，照搬 CodexBar toUsageSnapshot）——
        let hasFallbackCredits = promoSum > 0 || purchasedSum > 0

        // primary：月度 recurring 额度池。
        let primary: RateWindow? = {
            if recurringSum > 0 {
                return RateWindow(
                    title: L("月度额度"),
                    usedPercent: usedFromRecurring / recurringSum * 100,
                    resetsAt: renewalDate,
                    resetDescription: L("%ld/%ld credits", Int(usedFromRecurring.rounded()), Int(recurringSum)))
            }
            // recurring 缺失但有 bonus/purchased 时，省掉 0/0 假窗。
            if hasFallbackCredits { return nil }
            return RateWindow(
                title: L("月度额度"), usedPercent: 100, resetsAt: renewalDate,
                resetDescription: L("%ld/%ld credits", 0, 0))
        }()

        // secondary：promotional 赠送额度（总为 0 时记 100% 让进度条画空）。
        var promoDesc = L("%ld/%ld 赠送", Int(usedFromPromo.rounded()), Int(promoSum))
        if let expiry = promoExpiration {
            promoDesc += " · " + L("%@ 到期", Self.promoExpiryFormatter.string(from: expiry))
        }
        let secondary = RateWindow(
            title: L("赠送额度"),
            usedPercent: promoSum > 0 ? usedFromPromo / promoSum * 100 : 100,
            resetDescription: promoDesc)

        // tertiary：按需购买额度。
        let tertiary = RateWindow(
            title: L("购买额度"),
            usedPercent: purchasedSum > 0 ? usedFromPurchased / purchasedSum * 100 : 100,
            resetDescription: L("%ld/%ld credits", Int(usedFromPurchased.rounded()), Int(purchasedSum)))

        // 可用余额（balance_cents）→ providerCost，把 credits 余额显式补回来。
        let balance = max(0, response.balanceCents)
        let providerCost = ProviderCostSnapshot(
            used: balance, limit: 0, currencyCode: "Credits", period: L("余额"))

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: providerCost,
            planName: planName,
            updatedAt: now)
    }

    private static let promoExpiryFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt
    }()
}
