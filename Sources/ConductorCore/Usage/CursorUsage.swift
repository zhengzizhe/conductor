import Foundation
import SweetCookieKit

/// Cursor 用量取数。摘自 CodexBar `Cursor` provider 的浏览器 cookie 路径(用 SweetCookieKit):
/// 从浏览器里取 cursor.com 的登录 cookie → `GET cursor.com/api/usage-summary` → 解析套餐用量百分比。
///
/// 这是 cookie 类 provider 的样板。注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；
/// Safari 需要「完全磁盘访问」。无登录态/无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum CursorUsageError: LocalizedError, Sendable {
    case noSession
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 Cursor 登录态，请在浏览器登录 cursor.com（Safari 需开启完全磁盘访问）")
        case .unauthorized: L("Cursor 登录态已失效，请重新登录 cursor.com")
        case let .server(c): L("Cursor 接口错误（%ld）", c)
        case .invalidResponse: L("Cursor 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum CursorUsageFetcher {
    private static let cookieDomains = ["cursor.com", "www.cursor.com", "cursor.sh", "authenticator.cursor.sh"]
    private static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken", "__Secure-next-auth.session-token", "next-auth.session-token",
        "wos-session", "__Secure-wos-session", "authjs.session-token", "__Secure-authjs.session-token",
    ]

    /// 是否能从浏览器拿到 Cursor 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 cursor.com 的 cookie，拼成 Cookie 头；要求至少含一个已知会话 cookie。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "cursor", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "cursor", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            let hasNamed = cookies.contains { sessionCookieNames.contains($0.name) }
            guard hasNamed || !cookies.isEmpty else { continue }
            // 优先返回含已知会话名的那组；否则也返回（让 API 去校验）。
            if hasNamed || browser == Browser.defaultImportOrder.last {
                return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
            if !hasNamed { continue }
        }
        // 兜底：任意浏览器的 cursor 域 cookie。
        for browser in Browser.defaultImportOrder {
            if let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty {
                return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        return nil
    }

    public static func fetch(session: URLSession = .shared) async throws -> UsageSnapshot {
        guard let header = cookieHeader() else { throw CursorUsageError.noSession }

        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(header, forHTTPHeaderField: "Cookie")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw CursorUsageError.invalidResponse }
            data = d; http = h
        } catch let e as CursorUsageError {
            throw e
        } catch {
            throw CursorUsageError.network(error.localizedDescription)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw CursorUsageError.unauthorized }
        guard http.statusCode == 200 else { throw CursorUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    private struct Summary: Decodable {
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let membershipType: String?
        let individualUsage: Individual?
        let teamUsage: Team?

        struct Individual: Decodable {
            let plan: Plan?
            let onDemand: OnDemand?
            let overall: Cap?
        }
        struct Plan: Decodable {
            let used: Int?
            let limit: Int?
            let autoPercentUsed: Double?
            let apiPercentUsed: Double?
            let totalPercentUsed: Double?
        }
        struct Cap: Decodable { let used: Int?; let limit: Int? }
        // On-demand / spend（单位为分 cents）→ 进 providerCost 的 $。
        struct OnDemand: Decodable { let used: Int?; let limit: Int? }
        struct Team: Decodable { let onDemand: OnDemand?; let pooled: Cap? }
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let summary: Summary
        do { summary = try JSONDecoder().decode(Summary.self, from: data) }
        catch { throw CursorUsageError.invalidResponse }

        func norm(_ v: Double?) -> Double? { v.map { max(0, min(100, $0)) } }
        let plan = summary.individualUsage?.plan
        let auto = norm(plan?.autoPercentUsed)
        let api = norm(plan?.apiPercentUsed)
        let planUsed = Double(plan?.used ?? 0)
        let planLimit = Double(plan?.limit ?? 0)
        let overallUsed = (summary.individualUsage?.overall?.used).map(Double.init)
        let overallLimit = (summary.individualUsage?.overall?.limit).map(Double.init)
        let pooledUsed = (summary.teamUsage?.pooled?.used).map(Double.init)
        let pooledLimit = (summary.teamUsage?.pooled?.limit).map(Double.init)

        let percent: Double = if let total = plan?.totalPercentUsed {
            max(0, min(100, total))
        } else if let a = auto, let b = api {
            max(0, min(100, (a + b) / 2))
        } else if let b = api {
            b
        } else if let a = auto {
            a
        } else if planLimit > 0 {
            max(0, min(100, planUsed / planLimit * 100))
        } else if let u = overallUsed, let l = overallLimit, l > 0 {
            max(0, min(100, u / l * 100))
        } else if let u = pooledUsed, let l = pooledLimit, l > 0 {
            max(0, min(100, u / l * 100))
        } else {
            0
        }

        let end = parseISO(summary.billingCycleEnd)
        let start = parseISO(summary.billingCycleStart)
        let windowMinutes: Int? = (start != nil && end != nil)
            ? max(1, Int(end!.timeIntervalSince(start!) / 60)) : nil

        // primary：计费周期总用量（CodexBar planPercentUsed）。
        let primary = RateWindow(
            title: L("本期"),
            usedPercent: percent,
            windowMinutes: windowMinutes,
            resetsAt: end)
        // secondary / tertiary：Auto+Composer 与 API（命名模型）分车道百分比（CodexBar 同名窗）。
        let secondary: RateWindow? = auto.map {
            RateWindow(title: "Auto", usedPercent: $0, windowMinutes: windowMinutes, resetsAt: end)
        }
        let tertiary: RateWindow? = api.map {
            RateWindow(title: "API", usedPercent: $0, windowMinutes: windowMinutes, resetsAt: end)
        }

        // providerCost：on-demand / spend 美元用量（分→元）。优先个人 on-demand，其次团队 on-demand。
        // CodexBar 在 used>0 或 limit>0 时才组装（含首次消费前的预算上限）。
        let onDemandUsed = summary.individualUsage?.onDemand?.used
        let onDemandLimit = summary.individualUsage?.onDemand?.limit
        let teamOnDemandUsed = summary.teamUsage?.onDemand?.used
        let teamOnDemandLimit = summary.teamUsage?.onDemand?.limit
        let resolvedUsedCents: Int
        let resolvedLimitCents: Int?
        if (onDemandLimit ?? 0) > 0 {
            resolvedUsedCents = onDemandUsed ?? 0
            resolvedLimitCents = onDemandLimit
        } else if (teamOnDemandLimit ?? 0) > 0 {
            resolvedUsedCents = teamOnDemandUsed ?? 0
            resolvedLimitCents = teamOnDemandLimit
        } else {
            resolvedUsedCents = onDemandUsed ?? 0
            resolvedLimitCents = onDemandLimit
        }
        let providerCost: ProviderCostSnapshot? = (resolvedUsedCents > 0 || (resolvedLimitCents ?? 0) > 0)
            ? ProviderCostSnapshot(
                used: Double(resolvedUsedCents) / 100.0,
                limit: Double(resolvedLimitCents ?? 0) / 100.0,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: end)
            : nil

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: providerCost,
            planName: summary.membershipType)
    }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
