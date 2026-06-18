import Foundation
import SweetCookieKit

/// Manus（manus.im，按 credits 计费的通用 Agent）用量取数。忠实移植自 CodexBar `Manus` provider
/// （`ManusUsageFetcher` + `ManusSettingsReader` + `ManusCookieHeader` + `ManusCookieImporter`）。
///
/// 凭证有两路（**优先 token**）：
/// 1. token：环境变量里的 session token（`MANUS_SESSION_TOKEN` / `MANUS_SESSION_ID` / `MANUS_COOKIE`，
///    大小写两种键；若值是整段 cookie 头则从中抽 `session_id`）。
/// 2. cookie：从浏览器里取 manus.im 的 `session_id` cookie（SweetCookieKit）。
/// 两路拿到的都是同一个 session token，作 `Bearer` 调
/// `POST https://api.manus.im/user.v1.UserService/GetAvailableCredits`（空 body `{}`，Connect 协议），
/// 解析 credits 余额，换算成月度（proMonthly）与刷新（refresh）两个额度窗口。
///
/// 快照映射照搬 CodexBar `toUsageSnapshot()`，组装成富 `UsageSnapshot`：
///  - 月度窗（primary）= `(proMonthlyCredits - periodicCredits) / proMonthlyCredits * 100`；
///    Manus 不返回月度重置时刻，无周期 → 不带 reset；proMonthlyCredits<=0 则无此窗。
///  - 刷新窗（secondary）= `(maxRefreshCredits - refreshCredits) / maxRefreshCredits * 100`；
///    reset 用 `nextRefreshTime`；maxRefreshCredits<=0 则无此窗。
///  - 积分余额（providerCost）= `totalCredits`（CodexBar 把它塞进 "Balance: X credits" 文本，
///    conductor 改成结构化 `ProviderCostSnapshot`：used=余额、limit=0 无上限、currencyCode "Credits"）。
///
/// cookie 路径注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 照搬自 CodexBar，本机无登录态 / 无 token 无法实跑验证。
public enum ManusUsageError: LocalizedError, Sendable {
    case missingToken
    case invalidToken
    case server(Int)
    case invalidResponse
    case apiError(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 Manus 登录态，请设置环境变量 MANUS_SESSION_TOKEN 或在浏览器登录 manus.im（Safari 需开启完全磁盘访问）")
        case .invalidToken: L("Manus 登录态无效或已过期，请重新登录 manus.im")
        case let .server(code): L("Manus 接口错误（%ld）", code)
        case .invalidResponse: L("Manus 用量接口返回异常")
        case let .apiError(m): L("Manus API 错误：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum ManusUsageFetcher {
    private static let creditsURL =
        URL(string: "https://api.manus.im/user.v1.UserService/GetAvailableCredits")!
    /// manus.im 的会话 cookie 名（CodexBar `ManusCookieHeader.sessionCookieName`）。
    private static let sessionCookieName = "session_id"
    private static let cookieDomains = ["manus.im", "www.manus.im"]

    /// 是否配置了 Manus 的 session token 环境变量（纯本地检查，不发网络、不读浏览器）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    /// 是否能从浏览器拿到 Manus 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieToken() != nil
    }

    // MARK: - 凭证（优先 token，其次 cookie）

    /// 从环境变量解析 session token（照搬 CodexBar `ManusSettingsReader`）。
    static func token(env: [String: String]) -> String? {
        let rawToken = env["MANUS_SESSION_TOKEN"]
            ?? env["manus_session_token"]
            ?? env["MANUS_SESSION_ID"]
            ?? env["manus_session_id"]
        if let token = tokenFrom(cleaned(rawToken)) {
            return token
        }
        let rawCookie = env["MANUS_COOKIE"] ?? env["manus_cookie"]
        return tokenFrom(cleaned(rawCookie))
            ?? tokenFrom(UsageProviderRuntimeConfig.manualCookieHeader(providerID: "manus", env: env))
    }

    /// 从浏览器 cookie 抽取 manus.im 的 `session_id`（照搬 CodexBar `ManusCookieImporter`/`ManusCookieHeader`）。
    static func cookieToken(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "manus", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            for cookie in cookies where cookie.name.caseInsensitiveCompare(sessionCookieName) == .orderedSame {
                let token = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token }
            }
        }
        return nil
    }

    /// 优先 token（env），其次 cookie（浏览器）。
    static func resolveSessionToken(env: [String: String]) -> String? {
        token(env: env) ?? cookieToken(env: env)
    }

    /// raw 可能是裸 token、`session_id=...` 或整段 cookie 头；从中取出 token。
    /// 照搬 CodexBar `ManusCookieHeader.token(from:)`。
    private static func tokenFrom(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // 既不含 `=` 也不含 `;` → 视作裸 token。
        if !raw.contains("="), !raw.contains(";") { return raw }
        for pair in raw.components(separatedBy: ";") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare(sessionCookieName) == .orderedSame else { continue }
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// 去引号、去首尾空白（照搬 CodexBar `ManusSettingsReader.cleaned`）。
    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let sessionToken = resolveSessionToken(env: env) else { throw ManusUsageError.missingToken }
        let credits = try await fetchCredits(sessionToken: sessionToken, session: session)
        return makeSnapshot(credits)
    }

    static func fetchCredits(
        sessionToken: String,
        session: URLSession = .shared) async throws -> ManusCreditsResponse
    {
        guard !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManusUsageError.missingToken
        }

        var request = URLRequest(url: creditsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://manus.im", forHTTPHeaderField: "Origin")
        request.setValue("https://manus.im/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw ManusUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as ManusUsageError {
            throw e
        } catch {
            throw ManusUsageError.network(error.localizedDescription)
        }

        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ManusUsageError.invalidToken }
            throw ManusUsageError.apiError("HTTP \(http.statusCode)")
        }

        do {
            return try parseResponse(data)
        } catch let e as ManusUsageError {
            throw e
        } catch {
            throw ManusUsageError.invalidResponse
        }
    }

    // MARK: - 解析

    /// credits 接口可能直返 credits 对象，也可能裹在 `data`/`result`/`response`/`availableCredits` 信封里。
    /// 照搬 CodexBar `parseResponse`：先试信封（避免直解码因缺字段默认 0 而误判成功），再试裸对象并校验含期望键。
    static func parseResponse(_ data: Data) throws -> ManusCreditsResponse {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ManusCreditsEnvelope.self, from: data),
           let response = envelope.data ?? envelope.result ?? envelope.response ?? envelope.availableCredits
        {
            return response
        }

        let response = try decoder.decode(ManusCreditsResponse.self, from: data)
        guard payloadContainsCreditsField(data: data) else {
            throw ManusUsageError.apiError("response missing expected credits fields")
        }
        return response
    }

    private static let expectedCreditsKeys: Set<String> = [
        "totalCredits", "freeCredits", "periodicCredits", "addonCredits",
        "refreshCredits", "maxRefreshCredits", "proMonthlyCredits", "eventCredits",
    ]

    private static func payloadContainsCreditsField(data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return !expectedCreditsKeys.isDisjoint(with: object.keys)
    }

    // MARK: - 快照映射（照搬 CodexBar `ManusCreditsResponse.toUsageSnapshot`）

    private static func makeSnapshot(_ credits: ManusCreditsResponse, now: Date = Date()) -> UsageSnapshot {
        // 月度窗（primary）：已用 = (proMonthly - periodic) / proMonthly * 100；Manus 无月度重置时刻 → 不带 reset。
        let primary: RateWindow? = if credits.proMonthlyCredits > 0 {
            RateWindow(
                title: L("月度"),
                usedPercent: (credits.proMonthlyCredits - credits.periodicCredits) / credits.proMonthlyCredits * 100)
        } else {
            nil
        }

        // 刷新窗（secondary）：已用 = (maxRefresh - refresh) / maxRefresh * 100；reset = nextRefreshTime。
        let secondary: RateWindow? = if credits.maxRefreshCredits > 0 {
            RateWindow(
                title: L("刷新"),
                usedPercent: (credits.maxRefreshCredits - credits.refreshCredits) / credits.maxRefreshCredits * 100,
                resetsAt: credits.nextRefreshTime)
        } else {
            nil
        }

        // 积分余额：接口给 totalCredits 余额、无上限 → 放 providerCost（limit=0 表示无上限，按余额展示）。
        let providerCost = ProviderCostSnapshot(
            used: max(0, credits.totalCredits),
            limit: 0,
            currencyCode: "Credits",
            period: L("余额")) // Balance

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            providerCost: providerCost,
            updatedAt: now)
    }
}

/// Manus credits 接口响应（照搬 CodexBar `ManusCreditsResponse`）。数值字段对 Double/Int/String 三态宽松解码。
struct ManusCreditsResponse: Decodable, Sendable {
    let totalCredits: Double
    let freeCredits: Double
    let periodicCredits: Double
    let addonCredits: Double
    let refreshCredits: Double
    let maxRefreshCredits: Double
    let proMonthlyCredits: Double
    let eventCredits: Double
    let nextRefreshTime: Date?
    let refreshInterval: String?

    private enum CodingKeys: String, CodingKey {
        case totalCredits
        case freeCredits
        case periodicCredits
        case addonCredits
        case refreshCredits
        case maxRefreshCredits
        case proMonthlyCredits
        case eventCredits
        case nextRefreshTime
        case refreshInterval
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.totalCredits = container.lossyDouble(forKey: .totalCredits) ?? 0
        self.freeCredits = container.lossyDouble(forKey: .freeCredits) ?? 0
        self.periodicCredits = container.lossyDouble(forKey: .periodicCredits) ?? 0
        self.addonCredits = container.lossyDouble(forKey: .addonCredits) ?? 0
        self.refreshCredits = container.lossyDouble(forKey: .refreshCredits) ?? 0
        self.maxRefreshCredits = container.lossyDouble(forKey: .maxRefreshCredits) ?? 0
        self.proMonthlyCredits = container.lossyDouble(forKey: .proMonthlyCredits) ?? 0
        self.eventCredits = container.lossyDouble(forKey: .eventCredits) ?? 0
        self.nextRefreshTime = container.flexibleDate(forKey: .nextRefreshTime)
        self.refreshInterval = try? container.decodeIfPresent(String.self, forKey: .refreshInterval)
    }
}

/// credits 可能被包在常见信封字段里（照搬 CodexBar `ManusCreditsEnvelope`）。
private struct ManusCreditsEnvelope: Decodable {
    let data: ManusCreditsResponse?
    let result: ManusCreditsResponse?
    let response: ManusCreditsResponse?
    let availableCredits: ManusCreditsResponse?
}

extension KeyedDecodingContainer {
    /// Double / Int / String 三态宽松解码（照搬 CodexBar `decodeLossyDoubleIfPresent`）。
    fileprivate func lossyDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let intValue = try? decodeIfPresent(Int.self, forKey: key) { return Double(intValue) }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// 先按 Date 解，回退到 ISO8601 字符串（照搬 CodexBar `decodeIfPresentFlexibleDate`）。
    fileprivate func flexibleDate(forKey key: Key) -> Date? {
        if let value = try? decodeIfPresent(Date.self, forKey: key) { return value }
        guard let stringValue = try? decodeIfPresent(String.self, forKey: key), !stringValue.isEmpty else {
            return nil
        }
        return ISO8601DateFormatter().date(from: stringValue)
    }
}
