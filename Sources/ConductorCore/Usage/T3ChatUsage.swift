import Foundation
import SweetCookieKit

/// T3 Chat 用量取数。忠实移植自 CodexBar `T3Chat` provider（`T3ChatUsageFetcher` +
/// `T3ChatCookieImporter` + `T3ChatUsageParser`），走「浏览器 cookie」路径，**不依赖任何 token / env**。
///
/// 取数路径：从浏览器里取 t3.chat（含 www.t3.chat）的登录 cookie → 拼成 Cookie 头 →
/// `GET https://t3.chat/api/trpc/getCustomerData`（tRPC，`trpc-accept: application/jsonl`）→
/// 按行扫 JSONL，定位含 `usageFourHourPercentage` / `usageMonthPercentage` / `subscription`+`usageBand`
/// 的 customerData 对象 → 解析两条限流窗口（4 小时 Base + 月度/计费周期 Overage）。
///
/// 这是 cookie 类 provider。注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；
/// Safari 需要「完全磁盘访问」。无登录态 / 无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum T3ChatUsageError: LocalizedError, Sendable {
    case noSessionCookie
    case invalidCredentials
    case vercelChallenge
    case server(Int)
    case invalidResponse
    case parseFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie: L("没有找到 T3 Chat 登录态，请在浏览器登录 t3.chat（Safari 需开启完全磁盘访问）")
        case .invalidCredentials: L("T3 Chat 登录态已失效或过期，请重新登录 t3.chat")
        case .vercelChallenge: L("T3 Chat 返回了 Vercel 安全校验，请稍后重试")
        case let .server(c): L("T3 Chat 接口错误（%ld）", c)
        case .invalidResponse: L("T3 Chat 用量接口返回异常")
        case let .parseFailed(m): L("无法解析 T3 Chat 用量数据：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum T3ChatUsageFetcher {
    private static let cookieDomains = ["t3.chat", "www.t3.chat"]
    /// CodexBar 抓取的 getCustomerData tRPC 请求形状（2026-05 捕获）。
    private static let input = #"{"0":{"json":{"sessionId":null},"meta":{"values":{"sessionId":["undefined"]}}}}"#
    private static let refererURL = "https://t3.chat/settings/customization"
    private static let origin = "https://t3.chat"
    /// 浏览器指纹默认值仅作兜底。
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// 是否能从浏览器拿到 T3 Chat 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 t3.chat 域的 cookie，拼成 `name=value; ...` 的 Cookie 头。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "t3chat", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "t3chat", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }

    public static func fetch(session: URLSession = .shared) async throws -> CodexUsageSnapshot {
        guard let header = cookieHeader() else { throw T3ChatUsageError.noSessionCookie }

        var request = URLRequest(url: try customerDataURL())
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/jsonl", forHTTPHeaderField: "trpc-accept")
        request.setValue("web-client", forHTTPHeaderField: "x-trpc-source")
        request.setValue("true", forHTTPHeaderField: "x-trpc-batch")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(refererURL, forHTTPHeaderField: "Referer")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("u=4", forHTTPHeaderField: "Priority")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(header, forHTTPHeaderField: "Cookie")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw T3ChatUsageError.invalidResponse }
            data = d; http = h
        } catch let e as T3ChatUsageError {
            throw e
        } catch {
            throw T3ChatUsageError.network(error.localizedDescription)
        }

        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw T3ChatUsageError.invalidCredentials }
            // CodexBar：429 + `x-vercel-mitigated: challenge` → Vercel 安全校验。
            if http.statusCode == 429,
               http.value(forHTTPHeaderField: "x-vercel-mitigated") == "challenge"
            {
                throw T3ChatUsageError.vercelChallenge
            }
            throw T3ChatUsageError.server(http.statusCode)
        }

        return try parse(data)
    }

    private static func customerDataURL() throws -> URL {
        var components = URLComponents(string: "https://t3.chat/api/trpc/getCustomerData")!
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: input),
        ]
        guard let url = components.url else {
            throw T3ChatUsageError.invalidResponse
        }
        return url
    }

    // MARK: - 解析（照搬 T3ChatUsageParser + T3ChatUsageSnapshot.toUsageSnapshot）

    private struct Subscription: Decodable {
        let productName: String?
        let currentPeriodEnd: TimeInterval?
    }

    private struct CustomerData: Decodable {
        let subTier: String?
        let subscription: Subscription?
        let usageBand: String?
        let usageFourHourPercentage: Double?
        let usageMonthPercentage: Double?
        let usageFourHourNextResetAt: TimeInterval?
        let usagePeriodPercentage: Double?
        let usageWindowNextResetAt: TimeInterval?

        /// 套餐名：优先订阅产品名，回退 subTier；按 `-` 分词首字母大写。
        var planName: String? {
            let raw = subscription?.productName ?? subTier
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw.split(separator: "-").map { part in
                part.prefix(1).uppercased() + String(part.dropFirst())
            }.joined(separator: " ")
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> CodexUsageSnapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            throw T3ChatUsageError.parseFailed(L("响应不是 UTF-8"))
        }
        // tRPC `application/jsonl`：按行扫描，定位 customerData 对象。
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: lineData) else { continue }
            guard let customerObject = findCustomerData(in: object) else { continue }
            let customer = try decodeCustomerData(customerObject)
            return makeSnapshot(customer, now: now)
        }
        throw T3ChatUsageError.parseFailed(L("未找到 customerData 对象"))
    }

    /// 深度优先搜含用量字段的字典（照搬 CodexBar 的 findCustomerData 判定）。
    private static func findCustomerData(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if dictionary["usageFourHourPercentage"] != nil ||
                dictionary["usageMonthPercentage"] != nil ||
                dictionary["subscription"] != nil && dictionary["usageBand"] != nil
            {
                return dictionary
            }
            for value in dictionary.values {
                if let found = findCustomerData(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findCustomerData(in: value) { return found }
            }
        }
        return nil
    }

    private static func decodeCustomerData(_ object: [String: Any]) throws -> CustomerData {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            return try JSONDecoder().decode(CustomerData.self, from: data)
        } catch {
            throw T3ChatUsageError.parseFailed(error.localizedDescription)
        }
    }

    /// CodexBar `toUsageSnapshot()`：
    /// primary（4 小时 Base 窗口）→ session；secondary（月度/计费周期 Overage）→ weekly。
    private static func makeSnapshot(_ customer: CustomerData, now: Date) -> CodexUsageSnapshot {
        // Base 窗口：4 小时；重置时间优先 usageFourHourNextResetAt，回退 usageWindowNextResetAt。
        let baseReset = date(fromMilliseconds: customer.usageFourHourNextResetAt)
            ?? date(fromMilliseconds: customer.usageWindowNextResetAt)
        let baseWindowSeconds = 4 * 60 * 60
        let session = CodexUsageSnapshot.Window(
            usedPercent: percent(customer.usageFourHourPercentage),
            resetAt: baseReset ?? now.addingTimeInterval(TimeInterval(baseWindowSeconds)),
            windowSeconds: baseWindowSeconds)

        // Overage 窗口：月度/计费周期；CodexBar 用订阅的 currentPeriodEnd 当重置。
        // 无订阅周期信息时不臆造窗口（reset=now+30天、weekly=nil 的兜底见下）。
        let secondaryPercentRaw = customer.usageMonthPercentage ?? customer.usagePeriodPercentage
        let overageReset = date(fromMilliseconds: customer.subscription?.currentPeriodEnd)
        let weekly: CodexUsageSnapshot.Window?
        if secondaryPercentRaw != nil || overageReset != nil {
            let windowSeconds = overageReset.map { max(1, Int($0.timeIntervalSince(now))) } ?? 30 * 24 * 3600
            weekly = CodexUsageSnapshot.Window(
                usedPercent: percent(secondaryPercentRaw),
                resetAt: overageReset ?? now.addingTimeInterval(TimeInterval(windowSeconds)),
                windowSeconds: windowSeconds)
        } else {
            weekly = nil
        }

        return CodexUsageSnapshot(planType: customer.planName, session: session, weekly: weekly)
    }

    /// 0...100 限幅取整。
    private static func percent(_ raw: Double?) -> Int {
        Int(min(100, max(0, raw ?? 0)).rounded())
    }

    /// CodexBar：T3 Chat 用量字段是 JS epoch 毫秒，部分订阅字段可能是秒。
    private static func date(fromMilliseconds raw: TimeInterval?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}
