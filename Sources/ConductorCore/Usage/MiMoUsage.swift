import Foundation
import SweetCookieKit

/// 小米 MiMo（Xiaomi MiMo）用量取数。摘自 CodexBar `MiMo` provider 的浏览器 cookie 路径(用 SweetCookieKit):
/// 从浏览器里取 platform.xiaomimimo.com 的登录 cookie（要求含 api-platform_serviceToken + userId）→
/// `GET platform.xiaomimimo.com/api/v1/tokenPlan/usage`（+ tokenPlan/detail 取套餐与周期）→
/// 解析 token 套餐的月度额度用量百分比。账号级（与具体 CLI 无关）。
///
/// MiMo 仅有 cookie 登录态（CodexBar 无 env token 路径），故照搬 cookie 样板（同 CursorUsage.swift）。
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 无登录态/无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum MiMoUsageError: LocalizedError, Sendable {
    case noSession
    case invalidCookie
    case unauthorized
    case loginRequired
    case server(Int)
    case invalidResponse
    case parseFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession:
            L("没有找到小米 MiMo 登录态，请在浏览器登录 platform.xiaomimimo.com（Safari 需开启完全磁盘访问）")
        case .invalidCookie:
            L("小米 MiMo 需要 api-platform_serviceToken 与 userId 两个 cookie，请重新登录 platform.xiaomimimo.com")
        case .unauthorized:
            L("小米 MiMo 登录态已失效，请重新登录 platform.xiaomimimo.com")
        case .loginRequired:
            L("小米 MiMo 需要登录")
        case let .server(c):
            L("小米 MiMo 接口错误（%ld）", c)
        case .invalidResponse:
            L("小米 MiMo 用量接口返回异常")
        case let .parseFailed(m):
            L("无法解析小米 MiMo 用量：%@", m)
        case let .network(m):
            L("网络错误：%@", m)
        }
    }
}

public enum MiMoUsageFetcher {
    private static let apiBase = "https://platform.xiaomimimo.com/api/v1"
    private static let cookieDomains = ["platform.xiaomimimo.com", "xiaomimimo.com"]
    /// 拼成 Cookie 头的最小必需集合（缺一即视为无登录态）。
    private static let requiredCookieNames: Set<String> = ["api-platform_serviceToken", "userId"]
    /// 一并带上的已知 cookie（存在则附带，不强制）。
    private static let knownCookieNames: Set<String> = [
        "api-platform_serviceToken", "userId", "api-platform_ph", "api-platform_slh",
    ]

    /// 是否能从浏览器拿到小米 MiMo 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 xiaomimimo.com 的 cookie，拼成 Cookie 头；要求必含 api-platform_serviceToken + userId。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "mimo", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "mimo", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            if let header = header(from: cookies) { return header }
        }
        return nil
    }

    /// 仅保留已知 cookie 且必含必需集合；按名字排序拼成 `name=value; ...`。
    static func header(from cookies: [HTTPCookie]) -> String? {
        var byName: [String: String] = [:]
        for cookie in cookies {
            guard knownCookieNames.contains(cookie.name) else { continue }
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            byName[cookie.name] = value
        }
        guard requiredCookieNames.isSubset(of: Set(byName.keys)) else { return nil }
        return byName.keys.sorted().compactMap { name in
            byName[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
    }

    public static func fetch(session: URLSession = .shared) async throws -> CodexUsageSnapshot {
        guard let header = cookieHeader() else { throw MiMoUsageError.noSession }

        // tokenPlan/usage 取额度用量，tokenPlan/detail 取套餐名与周期结束时间（缺失不致命）。
        async let usageData = fetchAuthenticated(path: "tokenPlan/usage", cookie: header, session: session)
        let detailData: Data? = try? await fetchAuthenticated(
            path: "tokenPlan/detail", cookie: header, session: session)

        let usage = try parseTokenPlanUsage(from: try await usageData)
        let detail: (planCode: String?, periodEnd: Date?) = {
            guard let detailData, let result = try? parseTokenPlanDetail(from: detailData) else {
                return (nil, nil)
            }
            return result
        }()

        return makeSnapshot(usage: usage, detail: detail)
    }

    private static func fetchAuthenticated(
        path: String,
        cookie: String,
        session: URLSession) async throws -> Data
    {
        let url = URL(string: apiBase)!.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("UTC+01:00", forHTTPHeaderField: "x-timeZone")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/#/console/balance", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw MiMoUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as MiMoUsageError {
            throw e
        } catch {
            throw MiMoUsageError.network(error.localizedDescription)
        }

        switch http.statusCode {
        case 200: return data
        case 401: throw MiMoUsageError.loginRequired
        case 403: throw MiMoUsageError.unauthorized
        default: throw MiMoUsageError.server(http.statusCode)
        }
    }

    // MARK: - 解析

    /// 把额度用量映射到 session 窗口；reset 用套餐周期结束时间，缺失则 now+30 天；weekly 恒为 nil。
    static func makeSnapshot(
        usage: (used: Int, limit: Int, percent: Double),
        detail: (planCode: String?, periodEnd: Date?),
        now: Date = Date()) -> CodexUsageSnapshot
    {
        // 额度→已用百分比：优先 used/limit*100，缺 limit 则回退接口给的 percent（0...1 → ×100）。
        let usedPercent: Int = {
            if usage.limit > 0 {
                return max(0, min(100, Int((Double(usage.used) / Double(usage.limit) * 100).rounded())))
            }
            return max(0, min(100, Int((usage.percent * 100).rounded())))
        }()
        let resetAt = detail.periodEnd ?? now.addingTimeInterval(30 * 24 * 3600)
        let windowSeconds = max(1, Int(resetAt.timeIntervalSince(now)))
        let planType = detail.planCode.map { $0.capitalized }

        let window = CodexUsageSnapshot.Window(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowSeconds: windowSeconds)
        return CodexUsageSnapshot(planType: planType, session: window, weekly: nil)
    }

    static func parseTokenPlanUsage(from data: Data) throws -> (used: Int, limit: Int, percent: Double) {
        let response: TokenPlanUsageResponse
        do { response = try JSONDecoder().decode(TokenPlanUsageResponse.self, from: data) }
        catch { throw MiMoUsageError.invalidResponse }

        guard response.code == 0 else {
            if response.code == 401 { throw MiMoUsageError.loginRequired }
            if response.code == 403 { throw MiMoUsageError.unauthorized }
            let msg = response.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MiMoUsageError.parseFailed(msg?.isEmpty == false ? msg! : "code \(response.code)")
        }

        guard let item = response.data?.monthUsage?.items.first else {
            throw MiMoUsageError.parseFailed("Missing token plan usage")
        }
        return (used: item.used, limit: item.limit, percent: item.percent)
    }

    static func parseTokenPlanDetail(from data: Data) throws -> (planCode: String?, periodEnd: Date?) {
        let response = try JSONDecoder().decode(TokenPlanDetailResponse.self, from: data)
        guard response.code == 0, let payload = response.data else { return (nil, nil) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let periodEnd = payload.currentPeriodEnd.flatMap { formatter.date(from: $0) }
        return (payload.planCode, periodEnd)
    }

    // MARK: - 报文结构

    private struct TokenPlanUsageResponse: Decodable {
        let code: Int
        let message: String?
        let data: Payload?

        struct Payload: Decodable {
            let monthUsage: MonthUsage?
        }

        struct MonthUsage: Decodable {
            let percent: Double
            let items: [UsageItem]
        }

        struct UsageItem: Decodable {
            let name: String
            let used: Int
            let limit: Int
            let percent: Double
        }
    }

    private struct TokenPlanDetailResponse: Decodable {
        let code: Int
        let message: String?
        let data: Payload?

        struct Payload: Decodable {
            let planCode: String?
            let currentPeriodEnd: String?
            let expired: Bool
        }
    }
}
