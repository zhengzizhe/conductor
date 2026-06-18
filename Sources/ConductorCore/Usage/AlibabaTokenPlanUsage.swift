import Foundation
import SweetCookieKit

/// 阿里百炼 Token Plan（团队版 token 套餐，区别于 Qwen=CodingPlan）用量取数。
/// 忠实移植自 CodexBar `Alibaba TokenPlan` provider（`AlibabaTokenPlanUsageFetcher` / `…CookieHeader`
/// / `…SettingsReader` / `…UsageSnapshot`）。这是 **cookie 类** provider：百炼控制台没有 API key 路径，
/// 凭证来自 `bailian.console.aliyun.com` 的登录 cookie。
///
/// 取数路径（照搬 CodexBar）：
///   1. 解析 Cookie 头 —— 优先环境变量 `ALIBABA_TOKEN_PLAN_COOKIE`（手动粘贴的整段 Cookie 头），
///      否则从浏览器里取 `bailian.console.aliyun.com` 的 cookie（SweetCookieKit）；
///   2. 先 GET 控制台仪表盘 HTML / `tool/user/info.json`，尽力抠出 `sec_token`（缺失也能继续，纯 cookie 请求）；
///   3. `POST https://bailian.console.aliyun.com/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3`
///      （`application/x-www-form-urlencoded`，body 带 `ProductCode=sfm_tokenplanteams_dp_cn`、region、可选 sec_token）；
///   4. 递归深搜返回 JSON（并展开内嵌 JSON 字符串）定位含配额字段的对象，取 总额 / 已用 / 剩余 / 重置时间 / 套餐名。
///
/// 额度 → 百分比：`usedPercent = clamp(used / total) * 100`（无 used 则 `total - remaining`）；
/// 整段算作 30 天「会话」窗（CodexBar 用 `30*24*60` 分钟），放主窗(session)、weekly = nil；
/// 缺重置时间则用 now + 30 天兜底。
///
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 无登录态 / 无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum AlibabaTokenPlanUsageError: LocalizedError, Sendable {
    case loginRequired
    case invalidCredentials
    case server(Int)
    case invalidResponse
    case apiError(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .loginRequired:
            L("没有找到阿里百炼登录态，请在浏览器登录 bailian.console.aliyun.com（Safari 需开启完全磁盘访问）")
        case .invalidCredentials: L("阿里百炼登录态已失效，请重新登录 bailian.console.aliyun.com")
        case let .server(c): L("阿里百炼接口错误（%ld）", c)
        case .invalidResponse: L("阿里百炼 Token Plan 用量接口返回异常")
        case let .apiError(m): L("阿里百炼 API 错误：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum AlibabaTokenPlanUsageFetcher {
    private static let gatewayBaseURLString = "https://bailian.console.aliyun.com"
    private static let dashboardOriginURLString = "https://bailian.console.aliyun.com"
    private static let currentRegionID = "cn-beijing"
    private static let bssServiceCode = "BssOpenAPI-V3"
    private static let subscriptionSummaryAction = "GetSubscriptionSummary"
    private static let tokenPlanProductCode = "sfm_tokenplanteams_dp_cn"
    private static let cookieEnvKey = "ALIBABA_TOKEN_PLAN_COOKIE"
    /// 浏览器 cookie 取数的域名。
    private static let cookieDomains = ["bailian.console.aliyun.com", "console.aliyun.com", "aliyun.com"]
    private static let browserLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let safariLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    static var dashboardURL: URL {
        URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
    }

    // MARK: - 凭证判定（两条路径，优先 token/env）

    /// 是否配置了环境变量 Cookie 头（`ALIBABA_TOKEN_PLAN_COOKIE`）。便宜的本地检查，不发网络、不弹钥匙串。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        envCookieHeader(env: env) != nil
    }

    /// 是否能从浏览器拿到百炼登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串授权框）。
    public static func hasSession() -> Bool {
        browserCookieHeader() != nil
    }

    static func envCookieHeader(env: [String: String]) -> String? {
        normalize(
            clean(env[cookieEnvKey])
                ?? UsageProviderRuntimeConfig.manualCookieHeader(providerID: "alibabatokenplan", env: env))
    }

    /// 跨默认浏览器顺序取百炼域 cookie，拼成 `name=value; ...` 的 Cookie 头。
    static func browserCookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "alibabatokenplan", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            // 去重：同名 cookie 取 path/domain 最长、过期最晚的那条。
            var byName: [String: HTTPCookie] = [:]
            for cookie in cookies {
                guard !cookie.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                if let existing = byName[cookie.name], cookieSortKey(existing) >= cookieSortKey(cookie) { continue }
                byName[cookie.name] = cookie
            }
            guard !byName.isEmpty else { continue }
            return byName.keys.sorted().compactMap { name in
                byName[name].map { "\(name)=\($0.value)" }
            }.joined(separator: "; ")
        }
        return nil
    }

    private static func cookieSortKey(_ cookie: HTTPCookie) -> (Int, Int, Date) {
        (cookie.path.count, cookie.domain.count, cookie.expiresDate ?? .distantPast)
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        // 优先 env cookie 头，否则浏览器 cookie。
        guard let cookieHeader = envCookieHeader(env: env) ?? browserCookieHeader(env: env),
              let normalized = normalize(cookieHeader)
        else {
            throw AlibabaTokenPlanUsageError.loginRequired
        }

        let secToken = await resolveSECToken(cookieHeader: normalized, session: session)

        var request = URLRequest(url: defaultQuotaURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = subscriptionSummaryRequestBody(secToken: secToken)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(normalized, forHTTPHeaderField: "Cookie")
        if let csrf = extractCookieValue(name: "login_aliyunid_csrf", from: normalized)
            ?? extractCookieValue(name: "csrf", from: normalized)
        {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(browserLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(dashboardOriginURLString, forHTTPHeaderField: "Origin")
        request.setValue(dashboardURL.absoluteString, forHTTPHeaderField: "Referer")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw AlibabaTokenPlanUsageError.invalidResponse }
            data = d; http = h
        } catch let e as AlibabaTokenPlanUsageError {
            throw e
        } catch {
            throw AlibabaTokenPlanUsageError.network(error.localizedDescription)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw AlibabaTokenPlanUsageError.loginRequired }
        guard http.statusCode == 200 else { throw AlibabaTokenPlanUsageError.server(http.statusCode) }

        return try parse(data)
    }

    static var defaultQuotaURL: URL {
        var components = URLComponents(string: gatewayBaseURLString)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: subscriptionSummaryAction),
            URLQueryItem(name: "product", value: bssServiceCode),
            URLQueryItem(name: "_tag", value: ""),
        ]
        return components.url!
    }

    private static func subscriptionSummaryRequestBody(secToken: String?) -> Data {
        let paramsObject = ["ProductCode": tokenPlanProductCode]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
              let paramsString = String(data: paramsData, encoding: .utf8)
        else { return Data() }

        var components = URLComponents()
        var queryItems = [
            URLQueryItem(name: "product", value: bssServiceCode),
            URLQueryItem(name: "action", value: subscriptionSummaryAction),
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "region", value: currentRegionID),
        ]
        if let secToken, !secToken.isEmpty {
            queryItems.append(URLQueryItem(name: "sec_token", value: secToken))
        }
        components.queryItems = queryItems
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    // MARK: - sec_token 解析（尽力而为，缺失也能继续）

    private static func resolveSECToken(cookieHeader: String, session: URLSession) async -> String? {
        let cookieSECToken = extractCookieValue(name: "sec_token", from: cookieHeader)

        // ① 仪表盘 HTML。
        var request = URLRequest(url: dashboardURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(safariLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let html = String(data: data, encoding: .utf8),
           let token = extractSECToken(from: html)
        {
            return token
        }

        // ② tool/user/info.json。
        if let token = await fetchSECTokenFromUserInfo(cookieHeader: cookieHeader, session: session) {
            return token
        }

        // ③ 直接来自 cookie。
        if let cookieSECToken, !cookieSECToken.isEmpty { return cookieSECToken }
        return nil
    }

    private static func fetchSECTokenFromUserInfo(cookieHeader: String, session: URLSession) async -> String? {
        let userInfoURL = URL(string: dashboardOriginURLString)!.appendingPathComponent("tool/user/info.json")
        var request = URLRequest(url: userInfoURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(safariLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("\(dashboardOriginURLString)/", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        let expanded = expandedJSON(object)
        guard let token = findFirstString(forKeys: ["secToken", "sec_token"], in: expanded), !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: - 解析

    private static let planNameKeys = [
        "planName", "plan_name", "packageName", "package_name", "commodityName", "commodity_name",
        "instanceName", "instance_name", "displayName", "display_name", "ProductName", "productName",
        "name", "title", "planType", "plan_type",
    ]
    private static let usedQuotaKeys = [
        "usedQuota", "used_quota", "usedCredits", "usedCredit", "consumedCredits", "usage", "used",
        "usedAmount", "consumeAmount", "usedValue", "UsedValue", "consumedValue", "ConsumedValue",
    ]
    private static let totalQuotaKeys = [
        "totalQuota", "total_quota", "totalCredits", "totalCredit", "quota", "creditLimit", "creditsTotal",
        "monthlyTotalQuota", "amount", "totalValue", "TotalValue",
    ]
    private static let remainingQuotaKeys = [
        "remainingQuota", "remainQuota", "remainingCredits", "remainingCredit", "availableCredits", "balance",
        "remaining", "availableAmount", "remainAmount", "totalSurplusValue", "TotalSurplusValue",
        "surplusValue", "SurplusValue",
    ]
    private static let subscriptionCountKeys = [
        "totalCount", "TotalCount", "subscriptionTotalNumber", "SubscriptionTotalNumber",
    ]
    private static let resetDateKeys = [
        "nextRefreshTime", "resetTime", "periodEndTime", "billingCycleEnd", "billCycleEndTime", "expireTime",
        "expirationTime", "endTime", "validEndTime", "instanceEndTime", "nearestExpireDate", "NearestExpireDate",
    ]

    static func parse(_ data: Data, now: Date = Date()) throws -> CodexUsageSnapshot {
        guard !data.isEmpty else { throw AlibabaTokenPlanUsageError.invalidResponse }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            if isLikelyLoginHTML(data) { throw AlibabaTokenPlanUsageError.loginRequired }
            throw AlibabaTokenPlanUsageError.invalidResponse
        }
        let expanded = expandedJSON(object)
        guard let dictionary = expanded as? [String: Any] else { throw AlibabaTokenPlanUsageError.invalidResponse }

        try throwIfErrorPayload(dictionary)

        let summary = findSubscriptionSummary(in: dictionary) ?? dictionary
        let total = anyDouble(for: totalQuotaKeys, in: summary)
        let remaining = anyDouble(for: remainingQuotaKeys, in: summary)
        let used = anyDouble(for: usedQuotaKeys, in: summary)
            ?? total.flatMap { total in remaining.map { max(0, total - $0) } }
        let resetsAt = findResetDate(in: summary) ?? findResetDate(in: dictionary)
        let totalCount = anyDouble(for: subscriptionCountKeys, in: summary)
        let planName = findPlanName(in: summary) ?? ((totalCount ?? 0) > 0 || total != nil ? "TOKEN PLAN" : nil)

        if planName == nil, total == nil, used == nil, remaining == nil, totalCount == nil {
            throw AlibabaTokenPlanUsageError.invalidResponse
        }

        // 额度 → 已用百分比（与 CodexBar `usedPercent` 一致）。
        let usedPercent: Int? = {
            guard let total, total > 0 else { return nil }
            let usedValue: Double? = if let used {
                used
            } else if let remaining {
                total - remaining
            } else {
                nil
            }
            guard let usedValue else { return nil }
            let normalized = max(0, min(usedValue, total))
            return Int((normalized / total * 100).rounded())
        }()

        // 无周期：整段算 30 天「会话」窗（CodexBar windowMinutes = 30*24*60），weekly = nil。
        let windowSeconds = 30 * 24 * 60 * 60
        let session: CodexUsageSnapshot.Window? = usedPercent.map {
            CodexUsageSnapshot.Window(
                usedPercent: max(0, min(100, $0)),
                resetAt: resetsAt ?? now.addingTimeInterval(TimeInterval(windowSeconds)),
                windowSeconds: windowSeconds)
        }
        guard session != nil else { throw AlibabaTokenPlanUsageError.invalidResponse }

        let plan = planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexUsageSnapshot(
            planType: (plan?.isEmpty ?? true) ? nil : plan,
            session: session,
            weekly: nil)
    }

    private static func throwIfErrorPayload(_ dictionary: [String: Any]) throws {
        if parseBool(dictionary["successResponse"]) == false {
            if let statusCode = findFirstInt(forKeys: ["statusCode", "status_code", "code"], in: dictionary),
               statusCode == 401 || statusCode == 403
            {
                throw AlibabaTokenPlanUsageError.invalidCredentials
            }
            let code = findFirstString(forKeys: ["code", "status", "statusCode"], in: dictionary)
            let message = findFirstString(forKeys: ["message", "msg", "statusMessage"], in: dictionary)
                ?? code ?? "request was not successful"
            if isLoginOrTokenError(code: code, message: message) { throw AlibabaTokenPlanUsageError.loginRequired }
            throw AlibabaTokenPlanUsageError.apiError(message)
        }

        if findBoolValues(forKeys: ["Success", "success"], in: dictionary).contains(false) {
            let code = findFirstString(forKeys: ["Code", "code"], in: dictionary)
            let message = findFirstString(forKeys: ["Message", "message", "msg", "Code", "code"], in: dictionary)
                ?? "request was not successful"
            if isLoginOrTokenError(code: code, message: message) { throw AlibabaTokenPlanUsageError.loginRequired }
            throw AlibabaTokenPlanUsageError.apiError(message)
        }

        if let statusCode = findFirstInt(forKeys: ["statusCode", "status_code", "code"], in: dictionary),
           statusCode != 0, statusCode != 200
        {
            let message = findFirstString(forKeys: ["statusMessage", "status_msg", "message", "msg"], in: dictionary)
                ?? "status code \(statusCode)"
            if statusCode == 401 || statusCode == 403 { throw AlibabaTokenPlanUsageError.invalidCredentials }
            throw AlibabaTokenPlanUsageError.apiError(message)
        }

        let codeText = findFirstString(forKeys: ["code", "status", "statusCode"], in: dictionary)?.lowercased()
        let messageText = findFirstString(forKeys: ["message", "msg", "statusMessage"], in: dictionary)?.lowercased()
        if isLoginOrTokenError(code: codeText, message: messageText) { throw AlibabaTokenPlanUsageError.loginRequired }
    }

    private static func isLoginOrTokenError(code: String?, message: String?) -> Bool {
        let combined = [code, message].compactMap { $0?.lowercased() }.joined(separator: " ")
        return combined.contains("needlogin") || combined.contains("login")
            || combined.contains("postonlyortokenerror") || combined.contains("tokenerror")
            || combined.contains("request has expired") || combined.contains("refresh page")
            || combined.contains("请求已经过期")
    }

    private static func findSubscriptionSummary(in payload: [String: Any]) -> [String: Any]? {
        if let data = findFirstDictionary(
            forKeys: ["Data", "data", "successResponse", "success_response"], in: payload),
            containsSubscriptionSummaryFields(data)
        {
            return data
        }
        return findFirstDictionary(
            matchingAnyKey: usedQuotaKeys + totalQuotaKeys + remainingQuotaKeys + subscriptionCountKeys,
            in: payload)
    }

    private static func containsSubscriptionSummaryFields(_ payload: [String: Any]) -> Bool {
        let keys = usedQuotaKeys + totalQuotaKeys + remainingQuotaKeys + subscriptionCountKeys
        return keys.contains { payload[$0] != nil }
    }

    private static func findPlanName(in payload: [String: Any]) -> String? {
        anyString(for: planNameKeys, in: payload) ?? findFirstString(forKeys: planNameKeys, in: payload)
    }

    private static func findResetDate(in payload: [String: Any]) -> Date? {
        anyDate(for: resetDateKeys, in: payload) ?? findFirstDate(forKeys: resetDateKeys, in: payload)
    }

    private static func isLikelyLoginHTML(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<html")
            && (text.contains("login") || text.contains("sign in") || text.contains("signin"))
    }

    // MARK: - 递归查找

    private static func findFirstDictionary(forKeys keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            for key in keys where dict[key] is [String: Any] { return dict[key] as? [String: Any] }
            for nested in dict.values {
                if let found = findFirstDictionary(forKeys: keys, in: nested) { return found }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let found = findFirstDictionary(forKeys: keys, in: item) { return found }
            }
        }
        return nil
    }

    private static func findFirstDictionary(matchingAnyKey keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if keys.contains(where: { dict[$0] != nil }) { return dict }
            for nested in dict.values {
                if let found = findFirstDictionary(matchingAnyKey: keys, in: nested) { return found }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let found = findFirstDictionary(matchingAnyKey: keys, in: item) { return found }
            }
        }
        return nil
    }

    private static func findFirstString(forKeys keys: [String], in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = parseString(dict[key]) { return parsed }
            }
            for nested in dict.values {
                if let parsed = findFirstString(forKeys: keys, in: nested) { return parsed }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let parsed = findFirstString(forKeys: keys, in: item) { return parsed }
            }
        }
        return nil
    }

    private static func findBoolValues(forKeys keys: [String], in value: Any) -> [Bool] {
        if let dict = value as? [String: Any] {
            let direct = keys.compactMap { parseBool(dict[$0]) }
            let nested = dict.values.flatMap { findBoolValues(forKeys: keys, in: $0) }
            return direct + nested
        }
        if let array = value as? [Any] {
            return array.flatMap { findBoolValues(forKeys: keys, in: $0) }
        }
        return []
    }

    private static func findFirstInt(forKeys keys: [String], in value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = parseInt(dict[key]) { return parsed }
            }
            for nested in dict.values {
                if let parsed = findFirstInt(forKeys: keys, in: nested) { return parsed }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let parsed = findFirstInt(forKeys: keys, in: item) { return parsed }
            }
        }
        return nil
    }

    private static func findFirstDate(forKeys keys: [String], in value: Any) -> Date? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = parseDate(dict[key]) { return parsed }
            }
            for nested in dict.values {
                if let parsed = findFirstDate(forKeys: keys, in: nested) { return parsed }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let parsed = findFirstDate(forKeys: keys, in: item) { return parsed }
            }
        }
        return nil
    }

    /// 内嵌 JSON 字符串 → 解析展开；否则原样递归。
    private static func expandedJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var expanded: [String: Any] = [:]
            expanded.reserveCapacity(dict.count)
            for (key, nested) in dict { expanded[key] = expandedJSON(nested) }
            return expanded
        }
        if let array = value as? [Any] { return array.map { expandedJSON($0) } }
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data),
           nested is [String: Any] || nested is [Any]
        {
            return expandedJSON(nested)
        }
        return value
    }

    private static func anyString(for keys: [String], in dict: [String: Any]) -> String? {
        for key in keys {
            if let value = parseString(dict[key]) { return value }
        }
        return nil
    }

    private static func anyDouble(for keys: [String], in dict: [String: Any]) -> Double? {
        for key in keys {
            if let value = parseDouble(dict[key]) { return value }
        }
        return nil
    }

    private static func anyDate(for keys: [String], in dict: [String: Any]) -> Date? {
        for key in keys {
            if let value = parseDate(dict[key]) { return value }
        }
        return nil
    }

    // MARK: - 标量解析

    private static func parseInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = parseString(raw) { return Int(value) }
        return nil
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? Int64 { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = parseString(raw) { return Double(value.replacingOccurrences(of: ",", with: "")) }
        return nil
    }

    private static func parseString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let intValue = parseInt(raw) {
            if intValue > 1_000_000_000_000 { return Date(timeIntervalSince1970: TimeInterval(intValue) / 1000) }
            if intValue > 1_000_000_000 { return Date(timeIntervalSince1970: TimeInterval(intValue)) }
        }
        if let string = parseString(raw) {
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: string) { return date }
            }
        }
        return nil
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        guard let string = parseString(raw)?.lowercased() else { return nil }
        switch string {
        case "true", "1", "yes", "active", "valid", "normal": return true
        case "false", "0", "no", "inactive", "invalid", "expired": return false
        default: return nil
        }
    }

    // MARK: - Cookie / sec_token 辅助

    private static func clean(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 归一化 Cookie 头：拆分 `;`、丢弃空键值、用 `; ` 重新拼接。
    private static func normalize(_ raw: String?) -> String? {
        guard let raw = clean(raw) else { return nil }
        let pairs = raw.split(separator: ";").compactMap { part -> String? in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let pieces = trimmed.split(separator: "=", maxSplits: 1)
            guard let name = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            return trimmed
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    private static func extractCookieValue(name: String, from cookieHeader: String) -> String? {
        cookieHeader
            .split(separator: ";")
            .compactMap { part -> (String, String)? in
                let pieces = part.split(separator: "=", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard pieces.count == 2 else { return nil }
                return (pieces[0], pieces[1])
            }
            .first { $0.0 == name }?.1
    }

    private static func extractSECToken(from html: String) -> String? {
        let patterns = [
            #""secToken"\s*:\s*"([^"]+)""#,
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
        ]
        for pattern in patterns {
            if let token = matchFirstGroup(pattern: pattern, in: html), !token.isEmpty { return token }
        }
        return nil
    }

    private static func matchFirstGroup(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }
}
