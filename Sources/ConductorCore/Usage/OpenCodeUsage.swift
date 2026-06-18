import Foundation
import SweetCookieKit

/// OpenCode（opencode.ai 订阅）用量取数。忠实摘自 CodexBar `OpenCode` provider 的浏览器 cookie 路径：
/// 从浏览器取 opencode.ai 的登录 cookie（必须含 `auth` 或 `__Host-auth`）→ 调 `https://opencode.ai/_server`
/// 两次（先取 workspace id，再取该 workspace 的订阅用量）→ 解析 rollingUsage(5 小时) / weeklyUsage(周) 两个窗口。
///
/// 这是 cookie 类 provider（无 env API key / token 路径，源码 OpenCode 只有 cookie 模式）。
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 无登录态/无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
///
/// 可选环境变量：`CODEXBAR_OPENCODE_WORKSPACE_ID`（覆盖 workspace id，可填 `wrk_...` 或 billing 页 URL）。
public enum OpenCodeUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: L("OpenCode 登录态无效或已过期，请在浏览器登录 opencode.ai（Safari 需开启完全磁盘访问）")
        case let .networkError(message): L("网络错误：%@", message)
        case let .apiError(message): L("OpenCode 接口错误：%@", message)
        case let .parseFailed(message): L("OpenCode 用量接口返回异常：%@", message)
        }
    }
}

public enum OpenCodeUsageFetcher {
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let subscriptionServerID = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"

    private static let cookieDomains = ["opencode.ai", "app.opencode.ai"]
    /// 必需的会话 cookie 名（源码 OpenCodeCookieImporter 要求其一存在）。
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
    /// 订阅续期时刻字段（CodexBar renewAtKeys）；解析出来塞进 extraRateWindows 的「续期」命名窗。
    private static let renewAtKeys = ["renewAt", "renew_at"]

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    // MARK: - 凭证（cookie）

    /// 是否能从浏览器拿到 OpenCode 登录 cookie（含 auth/__Host-auth）。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 opencode.ai 域 cookie，要求至少含一个 auth/__Host-auth，拼成 `name=value; ...` Cookie 头。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "opencode", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "opencode", env: env) else {
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
        guard let header = cookieHeader(env: env) else { throw OpenCodeUsageError.invalidCredentials }
        let now = Date()

        let workspaceOverride = normalizeWorkspaceID(env["CODEXBAR_OPENCODE_WORKSPACE_ID"])
        let workspaceID: String = if let workspaceOverride {
            workspaceOverride
        } else {
            try await fetchWorkspaceID(cookieHeader: header, session: session)
        }

        let subscriptionText = try await fetchSubscriptionInfo(
            workspaceID: workspaceID,
            cookieHeader: header,
            session: session)
        return try parseSubscription(text: subscriptionText, now: now)
    }

    // MARK: - workspace id

    private static func fetchWorkspaceID(cookieHeader: String, session: URLSession) async throws -> String {
        let text = try await fetchServerText(
            serverID: workspacesServerID, args: nil, method: "GET", referer: baseURL,
            cookieHeader: cookieHeader, session: session)
        if looksSignedOut(text: text) { throw OpenCodeUsageError.invalidCredentials }

        var ids = parseWorkspaceIDs(text: text)
        if ids.isEmpty { ids = parseWorkspaceIDsFromJSON(text: text) }
        if let first = ids.first { return first }

        // GET 拿不到 → POST 兜底（与源码一致）。
        let fallback = try await fetchServerText(
            serverID: workspacesServerID, args: [], method: "POST", referer: baseURL,
            cookieHeader: cookieHeader, session: session)
        if looksSignedOut(text: fallback) { throw OpenCodeUsageError.invalidCredentials }
        ids = parseWorkspaceIDs(text: fallback)
        if ids.isEmpty { ids = parseWorkspaceIDsFromJSON(text: fallback) }
        guard let first = ids.first else { throw OpenCodeUsageError.parseFailed("Missing workspace id.") }
        return first
    }

    // MARK: - subscription

    private static func fetchSubscriptionInfo(
        workspaceID: String,
        cookieHeader: String,
        session: URLSession) async throws -> String
    {
        let referer = URL(string: "https://opencode.ai/workspace/\(workspaceID)/billing") ?? baseURL
        let text = try await fetchServerText(
            serverID: subscriptionServerID, args: [workspaceID], method: "GET", referer: referer,
            cookieHeader: cookieHeader, session: session)
        if looksSignedOut(text: text) { throw OpenCodeUsageError.invalidCredentials }
        if isExplicitNullPayload(text: text) { throw missingSubscriptionDataError(workspaceID: workspaceID) }

        // GET 解析不出 → POST 兜底（与源码一致）。
        if parseSubscriptionJSON(text: text, now: Date()) == nil,
           extractDouble(
               pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
               text: text) == nil
        {
            let fallback = try await fetchServerText(
                serverID: subscriptionServerID, args: [workspaceID], method: "POST", referer: referer,
                cookieHeader: cookieHeader, session: session)
            if looksSignedOut(text: fallback) { throw OpenCodeUsageError.invalidCredentials }
            if isExplicitNullPayload(text: fallback) { throw missingSubscriptionDataError(workspaceID: workspaceID) }
            return fallback
        }
        return text
    }

    private static func missingSubscriptionDataError(workspaceID: String) -> OpenCodeUsageError {
        OpenCodeUsageError.apiError(
            "No subscription usage data was returned for workspace \(workspaceID). " +
                "This usually means this workspace does not have OpenCode subscription quota data available.")
    }

    private static func isExplicitNullPayload(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("null") == .orderedSame { return true }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return false }
        return object is NSNull
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

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw OpenCodeUsageError.networkError("Invalid response") }
            data = d
            http = h
        } catch let error as OpenCodeUsageError {
            throw error
        } catch {
            throw OpenCodeUsageError.networkError(error.localizedDescription)
        }

        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if looksSignedOut(text: bodyText) { throw OpenCodeUsageError.invalidCredentials }
            if http.statusCode == 401 || http.statusCode == 403 { throw OpenCodeUsageError.invalidCredentials }
            if let message = extractServerErrorMessage(from: bodyText) {
                throw OpenCodeUsageError.apiError("HTTP \(http.statusCode): \(message)")
            }
            throw OpenCodeUsageError.apiError("HTTP \(http.statusCode)")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeUsageError.parseFailed("Response was not UTF-8.")
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

    // MARK: - 解析（→ UsageSnapshot）

    /// 内部窗口表示：已用百分比 + 距重置秒数。
    private struct Window {
        let percent: Double
        let resetInSec: Int
    }

    static func parseSubscription(text: String, now: Date) throws -> UsageSnapshot {
        if let snapshot = parseSubscriptionJSON(text: text, now: now) { return snapshot }

        // JSON 路径失败 → 退回正则直接抠字段（与源码一致）。正则路径拿不到 renewsAt。
        guard let rollingPercent = extractDouble(
            pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
            let rollingReset = extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text),
            let weeklyPercent = extractDouble(
                pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
            let weeklyReset = extractInt(
                pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        else {
            throw OpenCodeUsageError.parseFailed("Missing usage fields.")
        }

        return makeSnapshot(
            rolling: Window(percent: rollingPercent, resetInSec: rollingReset),
            weekly: Window(percent: weeklyPercent, resetInSec: weeklyReset),
            renewsAt: nil,
            now: now)
    }

    /// rolling → primary（5 小时会话窗），weekly → secondary（周窗）；
    /// renewsAt（若有）→ extraRateWindows 的「续期」命名窗（照搬 CodexBar 的 `renewal` 窗）。
    private static func makeSnapshot(
        rolling: Window,
        weekly: Window,
        renewsAt: Date?,
        now: Date) -> UsageSnapshot
    {
        let primary = makeRateWindow(rolling, title: L("会话"), windowMinutes: 5 * 60, now: now)
        let secondary = makeRateWindow(weekly, title: L("本周"), windowMinutes: 7 * 24 * 60, now: now)

        var extraWindows: [NamedRateWindow] = []
        if let renewsAt {
            let renewalWindow = RateWindow(
                title: L("续期"),
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: renewsAt)
            extraWindows.append(NamedRateWindow(id: "renewal", title: L("续期"), window: renewalWindow))
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: extraWindows,
            updatedAt: now)
    }

    private static func makeRateWindow(
        _ window: Window,
        title: String,
        windowMinutes: Int,
        now: Date) -> RateWindow
    {
        RateWindow(
            title: title,
            usedPercent: window.percent,
            windowMinutes: windowMinutes,
            resetsAt: now.addingTimeInterval(TimeInterval(window.resetInSec)))
    }

    private static func parseSubscriptionJSON(text: String, now: Date) -> UsageSnapshot? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }
        if let snapshot = parseUsageJSON(object: object, now: now) { return snapshot }
        return parseUsageFromCandidates(object: object, now: now)
    }

    private static func parseUsageJSON(object: Any, now: Date) -> UsageSnapshot? {
        guard let dict = object as? [String: Any] else { return nil }
        let renewsAt = dateValue(from: value(from: dict, keys: renewAtKeys))
        if let snapshot = parseUsageDictionary(dict, now: now, inheritedRenewsAt: renewsAt) { return snapshot }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let snapshot = parseUsageDictionary(nested, now: now, inheritedRenewsAt: renewsAt)
            {
                return snapshot
            }
        }
        if let snapshot = parseUsageNested(dict, now: now, depth: 0, inheritedRenewsAt: renewsAt) { return snapshot }
        return parseUsageFromCandidates(object: object, now: now, inheritedRenewsAt: renewsAt)
    }

    private static func parseUsageDictionary(
        _ dict: [String: Any],
        now: Date,
        inheritedRenewsAt: Date?) -> UsageSnapshot?
    {
        let renewsAt = dateValue(from: value(from: dict, keys: renewAtKeys)) ?? inheritedRenewsAt
        if let usage = dict["usage"] as? [String: Any],
           let snapshot = parseUsageDictionary(usage, now: now, inheritedRenewsAt: renewsAt)
        {
            return snapshot
        }
        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
        let weeklyKeys = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]
        let rolling = rollingKeys.compactMap { dict[$0] as? [String: Any] }.first
        let weekly = weeklyKeys.compactMap { dict[$0] as? [String: Any] }.first
        if let rolling, let weekly {
            return buildSnapshot(rolling: rolling, weekly: weekly, now: now, renewsAt: renewsAt)
        }
        return nil
    }

    private static func parseUsageNested(
        _ dict: [String: Any],
        now: Date,
        depth: Int,
        inheritedRenewsAt: Date?) -> UsageSnapshot?
    {
        if depth > 3 { return nil }
        let renewsAt = dateValue(from: value(from: dict, keys: renewAtKeys)) ?? inheritedRenewsAt
        var rolling: [String: Any]?
        var weekly: [String: Any]?
        for (key, value) in dict {
            guard let sub = value as? [String: Any] else { continue }
            let lower = key.lowercased()
            if lower.contains("rolling") {
                rolling = sub
            } else if lower.contains("weekly") || lower.contains("week") {
                weekly = sub
            }
        }
        if let rolling, let weekly,
           let snapshot = buildSnapshot(rolling: rolling, weekly: weekly, now: now, renewsAt: renewsAt)
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
        now: Date,
        renewsAt: Date?) -> UsageSnapshot?
    {
        guard let rollingWindow = parseWindow(rolling, now: now),
              let weeklyWindow = parseWindow(weekly, now: now)
        else { return nil }
        return makeSnapshot(rolling: rollingWindow, weekly: weeklyWindow, renewsAt: renewsAt, now: now)
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
        inheritedRenewsAt: Date? = nil) -> UsageSnapshot?
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
        let rolling = pickCandidate(preferred: rollingCandidates, fallback: candidates, pickShorter: true)
        let weekly = pickCandidate(
            preferred: weeklyCandidates, fallback: candidates, pickShorter: false, excluding: rolling?.id)
        guard let rolling, let weekly else { return nil }

        let renewsAt = dateValue(from: value(from: object as? [String: Any] ?? [:], keys: renewAtKeys))
            ?? inheritedRenewsAt
        return makeSnapshot(
            rolling: Window(percent: rolling.percent, resetInSec: rolling.resetInSec),
            weekly: Window(percent: weekly.percent, resetInSec: weekly.resetInSec),
            renewsAt: renewsAt,
            now: now)
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
