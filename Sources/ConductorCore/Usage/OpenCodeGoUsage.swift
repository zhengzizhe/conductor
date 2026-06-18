import Foundation
import SweetCookieKit

/// OpenCode (Go)（opencode.ai 的 `opencode-go` 订阅）用量取数。忠实摘自 CodexBar `OpenCodeGo` provider 的
/// 浏览器 cookie / Web 路径：从浏览器取 opencode.ai 域登录 cookie（必须含 `auth` 或 `__Host-auth`）→
/// 调 `https://opencode.ai/_server` 取 workspace id → GET 该 workspace 的用量页
/// `https://opencode.ai/workspace/{id}/go`（HTML）→ 解析 rollingUsage(5 小时) / weeklyUsage(周) 两个窗口。
///
/// 这是 cookie 类 provider：CodexBar 源码（`OpenCodeGoProviderDescriptor` / `ProviderTokenResolver`）只有 cookie
/// 模式，没有 env API key / token 凭证路径，故本实现只提供 `hasSession()`，不提供 `hasToken()`（无中生有）。
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 无登录态 / 无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
///
/// 已升级为富 `UsageSnapshot`：rollingUsage→primary、weeklyUsage→secondary、monthlyUsage→tertiary；
/// Zen 余额（额外抓 `https://opencode.ai/workspace/{id}` 页解析）→ providerCost（period "Zen balance"、
/// limit=0 表示无上限）；renewsAt→extraRateWindows 里的 "renewal" 命名窗。忠实摘自 CodexBar OpenCodeGo provider。
///
/// 可选环境变量：`CODEXBAR_OPENCODEGO_WORKSPACE_ID`（覆盖 workspace id，可填 `wrk_...` 或 workspace 页 URL）。
public enum OpenCodeGoUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: L("OpenCode (Go) 登录态无效或已过期，请在浏览器登录 opencode.ai（Safari 需开启完全磁盘访问）")
        case let .networkError(message): L("网络错误：%@", message)
        case let .apiError(message): L("OpenCode (Go) 接口错误：%@", message)
        case let .parseFailed(message): L("OpenCode (Go) 用量接口返回异常：%@", message)
        }
    }
}

public enum OpenCodeGoUsageFetcher {
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"

    private static let cookieDomains = ["opencode.ai", "app.opencode.ai"]
    /// 必需的会话 cookie 名（源码 OpenCodeWebCookieSupport.requestCookieNames）。
    private static let requiredCookieNames: Set<String> = ["auth", "__Host-auth"]

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private static let percentKeys = [
        "usagePercent", "usedPercent", "percentUsed", "percent",
        "usage_percent", "used_percent", "utilization", "utilizationPercent",
        "utilization_percent", "usage",
    ]
    private static let resetInKeys = [
        "resetInSec", "resetInSeconds", "resetSeconds", "reset_sec",
        "reset_in_sec", "resetsInSec", "resetsInSeconds", "resetIn", "resetSec",
    ]
    private static let resetAtKeys = [
        "resetAt", "resetsAt", "reset_at", "resets_at",
        "nextReset", "next_reset", "renewAt", "renew_at",
    ]
    private static let renewAtKeys = [
        "renewsAt", "renews_at", "renewAt", "renew_at",
        "renewalAt", "renewal_at", "nextRenewal", "next_renewal",
    ]

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    // MARK: - 凭证（cookie）

    /// 是否能从浏览器拿到 OpenCode (Go) 登录 cookie（含 auth/__Host-auth）。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 opencode.ai 域 cookie，要求至少含一个 auth/__Host-auth，拼成 `name=value; ...` Cookie 头。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "opencodego", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "opencodego", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            guard cookies.contains(where: { requiredCookieNames.contains($0.name) }) else { continue }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let header = cookieHeader(env: env) else { throw OpenCodeGoUsageError.invalidCredentials }
        let now = Date()

        let workspaceOverride = normalizeWorkspaceID(env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"])
        let workspaceID: String = if let workspaceOverride {
            workspaceOverride
        } else {
            try await fetchWorkspaceID(cookieHeader: header, session: session)
        }

        let usageText = try await fetchUsagePage(
            workspaceID: workspaceID,
            cookieHeader: header,
            session: session)
        let subscription = try parseSubscription(text: usageText, now: now)

        // Zen 余额：单独抓 workspace 主页（不带 /go）解析，best-effort，失败/缺字段则 nil（与源码一致）。
        let zenBalance = await fetchOptionalZenBalance(
            workspaceID: workspaceID,
            cookieHeader: header,
            session: session)

        return subscription.toUsageSnapshot(zenBalanceUSD: zenBalance)
    }

    // MARK: - workspace id

    private static func fetchWorkspaceID(cookieHeader: String, session: URLSession) async throws -> String {
        let text = try await fetchServerText(
            serverID: workspacesServerID, args: nil, method: "GET", referer: baseURL,
            cookieHeader: cookieHeader, session: session)
        if looksSignedOut(text: text) { throw OpenCodeGoUsageError.invalidCredentials }

        var ids = parseWorkspaceIDs(text: text)
        if ids.isEmpty { ids = parseWorkspaceIDsFromJSON(text: text) }
        if let first = ids.first { return first }

        // GET 拿不到 → POST 兜底（与源码一致）。
        let fallback = try await fetchServerText(
            serverID: workspacesServerID, args: [], method: "POST", referer: baseURL,
            cookieHeader: cookieHeader, session: session)
        if looksSignedOut(text: fallback) { throw OpenCodeGoUsageError.invalidCredentials }
        ids = parseWorkspaceIDs(text: fallback)
        if ids.isEmpty { ids = parseWorkspaceIDsFromJSON(text: fallback) }
        guard let first = ids.first else { throw OpenCodeGoUsageError.parseFailed("Missing workspace id.") }
        return first
    }

    // MARK: - usage page（GET HTML）

    /// 源码：GET `https://opencode.ai/workspace/{id}/go` 的整页 HTML，再从中抠用量。
    private static func fetchUsagePage(
        workspaceID: String,
        cookieHeader: String,
        session: URLSession) async throws -> String
    {
        let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go") ?? baseURL
        let text = try await fetchPageText(url: url, cookieHeader: cookieHeader, session: session)
        if looksSignedOut(text: text) { throw OpenCodeGoUsageError.invalidCredentials }

        // 源码校验：JSON 解得出 或 正则抠得到 rollingUsage.usagePercent，否则视作字段缺失。
        guard parseSubscriptionJSON(text: text, now: Date()) != nil ||
            extractDouble(
                pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
                text: text) != nil
        else {
            throw OpenCodeGoUsageError.parseFailed("Missing usage fields.")
        }
        return text
    }

    private static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 { return trimmed }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"), parts.count > index + 1 {
                let candidate = parts[index + 1]
                if candidate.hasPrefix("wrk_"), candidate.count > 4 { return candidate }
            }
        }
        if let match = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    // MARK: - Zen 余额（单独抓 workspace 主页，best-effort）

    /// 源码：GET `https://opencode.ai/workspace/{id}`（不带 /go），解析「Zen / current balance」美元数。
    /// best-effort —— 任何错误（网络 / 非 200 / 缺字段）都吞掉返回 nil，不影响主用量。
    private static func fetchOptionalZenBalance(
        workspaceID: String,
        cookieHeader: String,
        session: URLSession) async -> Double?
    {
        let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)") ?? baseURL
        guard let text = try? await fetchPageText(url: url, cookieHeader: cookieHeader, session: session) else {
            return nil
        }
        if looksSignedOut(text: text) { return nil }
        return parseZenBalance(text: text)
    }

    /// 先试 JSON 显式余额键，再退回本地化文本 / 邻近 "$金额" 正则（与源码 OpenCodeGoZenBalanceParser 一致）。
    static func parseZenBalance(text: String) -> Double? {
        if let value = parseZenBalanceJSON(text: text) { return value }
        let localizedPattern = [
            #"(?i)(?:current\s+balance|zen\s+balance|現在の残高)"#,
            #"[^$]{0,80}\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#,
        ].joined()
        if let value = extractDollarValue(pattern: localizedPattern, text: text) { return value }
        let nearbyPattern = #"(?i)(?:balance|残高)[\s\S]{0,120}?\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#
        return extractDollarValue(pattern: nearbyPattern, text: text)
    }

    private static func parseZenBalanceJSON(text: String) -> Double? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }
        return findBalanceValue(in: object)
    }

    private static func findBalanceValue(in object: Any) -> Double? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if isExplicitBalanceAmountKey(key), let number = balanceDoubleValue(from: value) { return number }
                if let found = findBalanceValue(in: value) { return found }
            }
            return nil
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findBalanceValue(in: value) { return found }
            }
        }
        return nil
    }

    private static func isExplicitBalanceAmountKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return [
            "zenbalance", "zencurrentbalance", "currentbalance",
            "currentbalanceusd", "balanceusd", "usdbalance",
        ].contains(normalized)
    }

    /// 余额专用：显式拒绝 Bool（避免把 true 当 1.0），其余同 doubleValue。
    private static func balanceDoubleValue(from value: Any?) -> Double? {
        switch value {
        case is Bool: nil
        case let number as Double: number
        case let number as NSNumber: number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ""))
        default: nil
        }
    }

    private static func extractDollarValue(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: ""))
    }

    // MARK: - HTTP

    private static func fetchServerText(
        serverID: String,
        args: [Any]?,
        method: String,
        referer: URL,
        cookieHeader: String,
        session: URLSession) async throws -> String
    {
        let url = serverRequestURL(serverID: serverID, args: args, method: method)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(serverID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if method.uppercased() != "GET", let args {
            request.httpBody = try JSONSerialization.data(withJSONObject: args, options: [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(request, session: session)
    }

    private static func fetchPageText(url: URL, cookieHeader: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        return try await send(request, session: session)
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> String {
        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else {
                throw OpenCodeGoUsageError.networkError("Invalid response")
            }
            data = d
            http = h
        } catch let error as OpenCodeGoUsageError {
            throw error
        } catch {
            throw OpenCodeGoUsageError.networkError(error.localizedDescription)
        }

        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if looksSignedOut(text: bodyText) { throw OpenCodeGoUsageError.invalidCredentials }
            if http.statusCode == 401 || http.statusCode == 403 { throw OpenCodeGoUsageError.invalidCredentials }
            if let message = extractServerErrorMessage(from: bodyText) {
                throw OpenCodeGoUsageError.apiError("HTTP \(http.statusCode): \(message)")
            }
            throw OpenCodeGoUsageError.apiError("HTTP \(http.statusCode)")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeGoUsageError.parseFailed("Response was not UTF-8.")
        }
        return text
    }

    private static func serverRequestURL(serverID: String, args: [Any]?, method: String) -> URL {
        guard method.uppercased() == "GET" else { return serverURL }
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "id", value: serverID)]
        if let args, !args.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: args, options: []),
           let encodedArgs = String(data: data, encoding: .utf8)
        {
            queryItems.append(URLQueryItem(name: "args", value: encodedArgs))
        }
        components?.queryItems = queryItems
        return components?.url ?? serverURL
    }

    // MARK: - 解析（→ Subscription → UsageSnapshot）

    /// 内部窗口表示：已用百分比 + 距重置秒数。
    private struct Window {
        let percent: Double
        let resetInSec: Int
    }

    /// 富内部表示：rolling/weekly + 可选 monthly + 可选 renewsAt + updatedAt（zen 余额在 fetch 阶段单独抓再合并）。
    /// 对应 CodexBar `OpenCodeGoUsageSnapshot` 的字段集合，最终经 `toUsageSnapshot` 映射到 conductor 富模型。
    private struct Subscription {
        let rolling: Window
        let weekly: Window
        let monthly: Window?
        let renewsAt: Date?
        let updatedAt: Date

        /// rolling→primary（5 小时）、weekly→secondary（周）、monthly→tertiary（月，可空）；
        /// zenBalanceUSD→providerCost（period "Zen balance"、limit=0 无上限）；renewsAt→"renewal" 额外命名窗。
        func toUsageSnapshot(zenBalanceUSD: Double?) -> UsageSnapshot {
            func rate(_ window: Window, title: String, windowMinutes: Int) -> RateWindow {
                RateWindow(
                    title: title,
                    usedPercent: window.percent,
                    windowMinutes: windowMinutes,
                    resetsAt: self.updatedAt.addingTimeInterval(TimeInterval(window.resetInSec)))
            }

            var extraWindows: [NamedRateWindow] = []
            if let renewsAt = self.renewsAt {
                extraWindows.append(NamedRateWindow(
                    id: "renewal",
                    title: L("续订"),
                    window: RateWindow(usedPercent: 0, resetsAt: renewsAt)))
            }

            return UsageSnapshot(
                primary: rate(self.rolling, title: L("会话"), windowMinutes: 5 * 60),
                secondary: rate(self.weekly, title: L("本周"), windowMinutes: 7 * 24 * 60),
                tertiary: self.monthly.map { rate($0, title: L("本月"), windowMinutes: 30 * 24 * 60) },
                extraRateWindows: extraWindows,
                providerCost: zenBalanceUSD.map {
                    ProviderCostSnapshot(used: $0, limit: 0, currencyCode: "USD", period: L("Zen 余额"))
                },
                updatedAt: self.updatedAt)
        }
    }

    private static func parseSubscription(text: String, now: Date) throws -> Subscription {
        if let snapshot = parseSubscriptionJSON(text: text, now: now) { return snapshot }

        // JSON 路径失败 → 退回正则直接抠字段（与源码一致）。
        guard let rollingPercent = extractDouble(
            pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
            let rollingReset = extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text),
            let weeklyPercent = extractDouble(
                pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
            let weeklyReset = extractInt(
                pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        else {
            throw OpenCodeGoUsageError.parseFailed("Missing usage fields.")
        }

        let monthlyPercent = extractDouble(
            pattern: #"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text)
        let monthlyReset = extractInt(
            pattern: #"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        let monthly: Window? = (monthlyPercent != nil || monthlyReset != nil)
            ? Window(percent: monthlyPercent ?? 0, resetInSec: monthlyReset ?? 0)
            : nil

        return Subscription(
            rolling: Window(percent: rollingPercent, resetInSec: rollingReset),
            weekly: Window(percent: weeklyPercent, resetInSec: weeklyReset),
            monthly: monthly,
            renewsAt: nil,
            updatedAt: now)
    }

    private static func parseSubscriptionJSON(text: String, now: Date) -> Subscription? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }
        let dict = object as? [String: Any]
        let renewsAt = dict.flatMap { dateValue(from: value(from: $0, keys: renewAtKeys)) }
        if let snapshot = parseUsageJSON(object: object, now: now, inheritedRenewsAt: renewsAt) { return snapshot }
        return parseUsageFromCandidates(object: object, now: now, inheritedRenewsAt: renewsAt)
    }

    private static func parseUsageJSON(object: Any, now: Date, inheritedRenewsAt: Date?) -> Subscription? {
        guard let dict = object as? [String: Any] else { return nil }
        if let snapshot = parseUsageDictionary(dict, now: now, inheritedRenewsAt: inheritedRenewsAt) { return snapshot }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let snapshot = parseUsageDictionary(nested, now: now, inheritedRenewsAt: inheritedRenewsAt)
            {
                return snapshot
            }
        }
        if let snapshot = parseUsageNested(dict, now: now, depth: 0, inheritedRenewsAt: inheritedRenewsAt) {
            return snapshot
        }
        return parseUsageFromCandidates(object: object, now: now, inheritedRenewsAt: inheritedRenewsAt)
    }

    private static func parseUsageDictionary(
        _ dict: [String: Any],
        now: Date,
        inheritedRenewsAt: Date?) -> Subscription?
    {
        let renewsAt = dateValue(from: value(from: dict, keys: renewAtKeys)) ?? inheritedRenewsAt
        if let usage = dict["usage"] as? [String: Any],
           let snapshot = parseUsageDictionary(usage, now: now, inheritedRenewsAt: renewsAt)
        {
            return snapshot
        }
        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
        let weeklyKeys = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]
        let monthlyKeys = ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow", "monthly_window"]
        let rolling = rollingKeys.compactMap { dict[$0] as? [String: Any] }.first
        let weekly = weeklyKeys.compactMap { dict[$0] as? [String: Any] }.first
        let monthly = monthlyKeys.compactMap { dict[$0] as? [String: Any] }.first
        if let rolling, let weekly {
            return buildSnapshot(rolling: rolling, weekly: weekly, monthly: monthly, now: now, renewsAt: renewsAt)
        }
        return nil
    }

    private static func parseUsageNested(
        _ dict: [String: Any],
        now: Date,
        depth: Int,
        inheritedRenewsAt: Date?) -> Subscription?
    {
        if depth > 3 { return nil }
        let renewsAt = dateValue(from: value(from: dict, keys: renewAtKeys)) ?? inheritedRenewsAt
        var rolling: [String: Any]?
        var weekly: [String: Any]?
        var monthly: [String: Any]?
        for (key, value) in dict {
            guard let sub = value as? [String: Any] else { continue }
            let lower = key.lowercased()
            if lower.contains("rolling") || lower.contains("hour") || lower.contains("5h") || lower.contains("5-hour") {
                rolling = sub
            } else if lower.contains("weekly") || lower.contains("week") {
                weekly = sub
            } else if lower.contains("monthly") || lower.contains("month") {
                monthly = sub
            }
        }
        if let rolling, let weekly,
           let snapshot = buildSnapshot(
               rolling: rolling, weekly: weekly, monthly: monthly, now: now, renewsAt: renewsAt)
        {
            return snapshot
        }
        for value in dict.values {
            if let sub = value as? [String: Any],
               let snapshot = parseUsageNested(sub, now: now, depth: depth + 1, inheritedRenewsAt: renewsAt)
            {
                return snapshot
            }
        }
        return nil
    }

    private static func buildSnapshot(
        rolling: [String: Any],
        weekly: [String: Any],
        monthly: [String: Any]?,
        now: Date,
        renewsAt: Date?) -> Subscription?
    {
        guard let rollingWindow = parseWindow(rolling, now: now),
              let weeklyWindow = parseWindow(weekly, now: now)
        else { return nil }
        let monthlyWindow = monthly.flatMap { parseWindow($0, now: now) }
        return Subscription(
            rolling: rollingWindow,
            weekly: weeklyWindow,
            monthly: monthlyWindow,
            renewsAt: renewsAt,
            updatedAt: now)
    }

    private struct WindowCandidate {
        let id: UUID
        let percent: Double
        let resetInSec: Int
        let pathLower: String
    }

    private static func parseUsageFromCandidates(
        object: Any,
        now: Date,
        inheritedRenewsAt: Date? = nil) -> Subscription?
    {
        let candidates = collectWindowCandidates(object: object, now: now)
        guard !candidates.isEmpty else { return nil }

        let rollingCandidates = candidates.filter {
            $0.pathLower.contains("rolling") || $0.pathLower.contains("hour") ||
                $0.pathLower.contains("5h") || $0.pathLower.contains("5-hour")
        }
        let weeklyCandidates = candidates.filter {
            $0.pathLower.contains("weekly") || $0.pathLower.contains("week")
        }
        let monthlyCandidates = candidates.filter {
            $0.pathLower.contains("monthly") || $0.pathLower.contains("month")
        }
        let rolling = pickCandidate(preferred: rollingCandidates, fallback: candidates, pickShorter: true)
        let weekly = pickCandidate(
            preferred: weeklyCandidates, fallback: candidates, pickShorter: false, excluding: rolling?.id)
        guard let rolling, let weekly else { return nil }
        let monthly = pickCandidate(
            from: monthlyCandidates.filter { $0.id != rolling.id && $0.id != weekly.id },
            pickShorter: false)

        let renewsAt = dateValue(from: value(from: object as? [String: Any] ?? [:], keys: renewAtKeys))
            ?? inheritedRenewsAt
        return Subscription(
            rolling: Window(percent: rolling.percent, resetInSec: rolling.resetInSec),
            weekly: Window(percent: weekly.percent, resetInSec: weekly.resetInSec),
            monthly: monthly.map { Window(percent: $0.percent, resetInSec: $0.resetInSec) },
            renewsAt: renewsAt,
            updatedAt: now)
    }

    private static func collectWindowCandidates(object: Any, now: Date) -> [WindowCandidate] {
        var candidates: [WindowCandidate] = []
        collectWindowCandidates(object: object, now: now, path: [], out: &candidates)
        return candidates
    }

    private static func collectWindowCandidates(
        object: Any,
        now: Date,
        path: [String],
        out: inout [WindowCandidate])
    {
        if let dict = object as? [String: Any] {
            if let window = parseWindow(dict, now: now) {
                out.append(WindowCandidate(
                    id: UUID(),
                    percent: window.percent,
                    resetInSec: window.resetInSec,
                    pathLower: path.joined(separator: ".").lowercased()))
            }
            for (key, value) in dict {
                collectWindowCandidates(object: value, now: now, path: path + [key], out: &out)
            }
            return
        }
        if let array = object as? [Any] {
            for (index, value) in array.enumerated() {
                collectWindowCandidates(object: value, now: now, path: path + ["[\(index)]"], out: &out)
            }
        }
    }

    private static func pickCandidate(
        preferred: [WindowCandidate],
        fallback: [WindowCandidate],
        pickShorter: Bool,
        excluding excluded: UUID? = nil) -> WindowCandidate?
    {
        let filteredPreferred = preferred.filter { $0.id != excluded }
        if let picked = pickCandidate(from: filteredPreferred, pickShorter: pickShorter) { return picked }
        let filteredFallback = fallback.filter { $0.id != excluded }
        return pickCandidate(from: filteredFallback, pickShorter: pickShorter)
    }

    private static func pickCandidate(from candidates: [WindowCandidate], pickShorter: Bool) -> WindowCandidate? {
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            if lhs.resetInSec == rhs.resetInSec { return lhs.percent > rhs.percent }
            return pickShorter ? lhs.resetInSec < rhs.resetInSec : lhs.resetInSec > rhs.resetInSec
        }
    }

    private static func parseWindow(_ dict: [String: Any], now: Date) -> Window? {
        var percent = doubleValue(from: dict, keys: percentKeys)
        if percent == nil {
            let used = doubleValue(from: dict, keys: ["used", "usage", "consumed", "count", "usedTokens"])
            let limit = doubleValue(from: dict, keys: ["limit", "total", "quota", "max", "cap", "tokenLimit"])
            if let used, let limit, limit > 0 { percent = (used / limit) * 100 }
        }
        guard var resolvedPercent = percent else { return nil }
        if resolvedPercent <= 1.0, resolvedPercent >= 0 { resolvedPercent *= 100 }
        resolvedPercent = max(0, min(100, resolvedPercent))

        var resetInSec = intValue(from: dict, keys: resetInKeys)
        if resetInSec == nil {
            if let resetAt = dateValue(from: value(from: dict, keys: resetAtKeys)) {
                resetInSec = max(0, Int(resetAt.timeIntervalSince(now)))
            }
        }
        return Window(percent: resolvedPercent, resetInSec: max(0, resetInSec ?? 0))
    }

    // MARK: - workspace id 解析

    static func parseWorkspaceIDs(text: String) -> [String] {
        let pattern = #"id\s*:\s*\"(wrk_[^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func parseWorkspaceIDsFromJSON(text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return [] }
        var results: [String] = []
        collectWorkspaceIDs(object: object, out: &results)
        return results
    }

    private static func collectWorkspaceIDs(object: Any, out: inout [String]) {
        if let dict = object as? [String: Any] {
            for value in dict.values { collectWorkspaceIDs(object: value, out: &out) }
            return
        }
        if let array = object as? [Any] {
            for value in array { collectWorkspaceIDs(object: value, out: &out) }
            return
        }
        if let string = object as? String, string.hasPrefix("wrk_"), !out.contains(string) {
            out.append(string)
        }
    }

    // MARK: - 辅助

    private static func looksSignedOut(text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login") ||
            lower.contains("sign in") ||
            lower.contains("auth/authorize") ||
            lower.contains("not associated with an account") ||
            lower.contains("actor of type \"public\"")
    }

    private static func extractServerErrorMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            if let match = text.range(of: #"(?i)<title>([^<]+)</title>"#, options: .regularExpression) {
                return String(text[match].dropFirst(7).dropLast(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        guard let dict = object as? [String: Any] else { return nil }
        if let message = dict["message"] as? String, !message.isEmpty { return message }
        if let error = dict["error"] as? String, !error.isEmpty { return error }
        if let detail = dict["detail"] as? String, !detail.isEmpty { return detail }
        return nil
    }

    private static func extractDouble(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range])
    }

    private static func extractInt(pattern: String, text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    private static func doubleValue(from value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }

    private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as Int: number
        case let number as NSNumber: number.intValue
        case let string as String: Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }

    private static func doubleValue(from dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = doubleValue(from: dict[key]) { return value }
        }
        return nil
    }

    private static func intValue(from dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(from: dict[key]) { return value }
        }
        return nil
    }

    private static func value(from dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] { return value }
        }
        return nil
    }

    private static func dateValue(from value: Any?) -> Date? {
        guard let value else { return nil }
        if let number = doubleValue(from: value) {
            if number > 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
            if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
        }
        if let string = value as? String {
            if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return dateValue(from: number)
            }
            if let parsed = makeISO8601Formatter().date(from: string) { return parsed }
        }
        return nil
    }
}
