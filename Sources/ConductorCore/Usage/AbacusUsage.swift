import Foundation
import SweetCookieKit

/// Abacus AI（Abacus.AI / CodeLLM）用量取数。摘自 CodexBar `Abacus` provider 的浏览器 cookie 路径（用 SweetCookieKit）：
/// 从浏览器里取 abacus.ai 的登录 cookie → 并发调
/// `GET apps.abacus.ai/api/_getOrganizationComputePoints`（额度，必需）+
/// `POST apps.abacus.ai/api/_getBillingInfo`（套餐/重置日，可选）→
/// 解析 compute points 余额算出已用百分比。
///
/// 这是 cookie 类 provider（无环境变量 token；CodexBar 的 ProviderTokenResolver 没有 Abacus 条目）。
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需「完全磁盘访问」。
/// 无登录态/无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum AbacusUsageError: LocalizedError, Sendable {
    case noSession
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 Abacus AI 登录态，请在浏览器登录 apps.abacus.ai（Safari 需开启完全磁盘访问）")
        case .unauthorized: L("Abacus AI 登录态已失效，请重新登录 apps.abacus.ai")
        case let .server(c): L("Abacus AI 接口错误（%ld）", c)
        case .invalidResponse: L("Abacus AI 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum AbacusUsageFetcher {
    private static let cookieDomains = ["abacus.ai", "apps.abacus.ai"]
    /// 已知会话 cookie 名（精确匹配优先），CSRF/分析类不算登录态。
    private static let sessionCookieNames: Set<String> = [
        "sessionid", "session_id", "session_token", "auth_token", "access_token",
    ]
    private static let computePointsURL =
        URL(string: "https://apps.abacus.ai/api/_getOrganizationComputePoints")!
    private static let billingInfoURL =
        URL(string: "https://apps.abacus.ai/api/_getBillingInfo")!

    /// 是否能从浏览器拿到 Abacus 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 abacus.ai 域的 cookie，拼成 Cookie 头；要求至少含一个会话类 cookie。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "abacus", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "abacus", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            guard containsSessionCookie(cookies) else { continue }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }

    /// 至少含一个会话/认证类 cookie 才认作登录态：先精确名匹配，再保守子串匹配（排除 csrf/分析）。
    private static func containsSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        let excludedPrefixes = ["csrf", "_ga", "_gid", "tracking", "analytics"]
        let substrings = ["session", "auth", "sid", "jwt"]
        return cookies.contains { cookie in
            let lower = cookie.name.lowercased()
            if sessionCookieNames.contains(lower) { return true }
            if excludedPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
            return substrings.contains { lower.contains($0) }
        }
    }

    public static func fetch(session: URLSession = .shared) async throws -> CodexUsageSnapshot {
        guard let header = cookieHeader() else { throw AbacusUsageError.noSession }

        // compute points 必需；billing info 可选（拿套餐名与重置日）。billing 失败不影响额度展示。
        async let pointsTask = request(computePointsURL, method: "GET", cookieHeader: header, session: session)
        async let billingTask = try? request(billingInfoURL, method: "POST", cookieHeader: header, session: session)

        let computePoints = try await pointsTask
        let billingInfo = await billingTask ?? [:]
        return try parse(computePoints: computePoints, billingInfo: billingInfo)
    }

    // MARK: - 请求

    /// 调用一个 Abacus 接口，校验状态码与 `{"success":true,"result":{...}}` 信封，返回 `result` 字典。
    private static func request(
        _ url: URL,
        method: String,
        cookieHeader: String,
        session: URLSession) async throws -> [String: Any]
    {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if method == "POST" { req.httpBody = Data("{}".utf8) }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: req)
            guard let h = response as? HTTPURLResponse else { throw AbacusUsageError.invalidResponse }
            data = d; http = h
        } catch let e as AbacusUsageError {
            throw e
        } catch {
            throw AbacusUsageError.network(error.localizedDescription)
        }

        if http.statusCode == 401 || http.statusCode == 403 { throw AbacusUsageError.unauthorized }
        guard http.statusCode == 200 else { throw AbacusUsageError.server(http.statusCode) }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AbacusUsageError.invalidResponse
        }
        guard root["success"] as? Bool == true, let result = root["result"] as? [String: Any] else {
            // 信封里若提示会话/登录失效，按未授权处理。
            let errorMsg = (root["error"] as? String ?? "").lowercased()
            let authKeywords = ["expired", "session", "login", "authenticate", "unauthorized",
                                "unauthenticated", "forbidden"]
            if authKeywords.contains(where: { errorMsg.contains($0) }) { throw AbacusUsageError.unauthorized }
            throw AbacusUsageError.invalidResponse
        }
        return result
    }

    // MARK: - 解析

    static func parse(computePoints: [String: Any], billingInfo: [String: Any]) throws -> CodexUsageSnapshot {
        guard let total = double(from: computePoints["totalComputePoints"]),
              let left = double(from: computePoints["computePointsLeft"])
        else { throw AbacusUsageError.invalidResponse }

        let used = total - left
        let percent = total > 0 ? max(0, min(100, used / total * 100)) : 0

        let planName = billingInfo["currentTier"] as? String
        let resetAt = parseISO(billingInfo["nextBillingDate"] as? String)

        // 有计费周期日 → 窗口取「重置日往前一个月」；否则无固定周期，回退 now+30 天。
        let now = Date()
        let windowSeconds: Int
        let reset: Date
        if let resetAt {
            reset = resetAt
            let cycleStart = Calendar.current.date(byAdding: .month, value: -1, to: resetAt) ?? resetAt
            windowSeconds = max(1, Int(resetAt.timeIntervalSince(cycleStart)))
        } else {
            reset = now.addingTimeInterval(30 * 24 * 3600)
            windowSeconds = 30 * 24 * 3600
        }

        let window = CodexUsageSnapshot.Window(
            usedPercent: Int(percent.rounded()),
            resetAt: reset,
            windowSeconds: windowSeconds)
        // Abacus 是单一额度（compute points）→ 放主窗（会话位）；无周窗。
        return CodexUsageSnapshot(planType: planName, session: window, weekly: nil)
    }

    private static func double(from value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
