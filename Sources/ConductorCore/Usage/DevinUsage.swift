import Foundation
#if os(macOS)
import SweetCookieKit
#endif

/// Devin（app.devin.ai 订阅）用量取数。忠实移植自 CodexBar `Devin` provider
/// （`DevinUsageFetcher.swift` / `DevinUsageSnapshot.swift` / `DevinSessionImporter.swift`）。
///
/// 凭证两条路，token 优先：
///  1. **token（env）**：手动 Bearer 令牌——`DEVIN_BEARER_TOKEN` 或 `DEVIN_AUTHORIZATION`
///     （会剥掉 `authorization:` / `bearer ` 前缀，对应源码 `manualAuth`）。组织来自
///     `DEVIN_ORGANIZATION` / `DEVIN_ORG`（可选；走 token 路时若 URL/键里推不出组织则报缺组织）。
///  2. **cookie（域名）**：从 Chromium 浏览器 localStorage（`https://app.devin.ai` 源）读 OAuth
///     access token（`auth1_session` 的 `token` 或 `auth0spajs@@::` 的 `access_token`），并从
///     `last-internal-org-for-external-org-v1-*` 等键推断组织 slug / 内部组织 ID。会触发浏览器本地存储读取。
///
/// 取数：`GET https://app.devin.ai/api/{organization}/billing/quota/usage`，`Bearer` 鉴权，
/// 若有内部组织 ID 再带 `x-cog-org-id`。组织路径有多种候选写法，逐个尝试（与源码 `candidatePaths` 一致）。
///
/// 解析（源码 `DevinUsageParser`）：优先 `daily_percentage` / `weekly_percentage`
/// （≤1 视作比例 ×100），否则深搜含 daily/week 的窗口；窗口里再认 used/limit → used/limit×100。
/// daily → session、weekly → weekly。Devin 配额按比例给（百分比即「已用」），故额度类一律 used/limit×100。
/// 无周期信息时按本仓约定：session 的 `reset = now + 30 天`、`weekly = nil`。
/// 本机无登录态/无令牌时报错，照搬自 CodexBar，无法实跑验证。
public enum DevinUsageError: LocalizedError, Sendable {
    case noSession
    case missingOrganization
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession:
            L("没有找到 Devin 登录态，请在浏览器登录 app.devin.ai，或设置环境变量 DEVIN_BEARER_TOKEN")
        case .missingOrganization:
            L("未找到 Devin 组织，请打开 app.devin.ai/org/... 页面，或设置环境变量 DEVIN_ORGANIZATION")
        case .unauthorized:
            L("Devin 登录态已失效，请重新登录 app.devin.ai")
        case let .server(code):
            L("Devin 接口错误（%ld）", code)
        case .invalidResponse:
            L("Devin 用量接口返回异常")
        case let .network(msg):
            L("网络错误：%@", msg)
        }
    }
}

public enum DevinUsageFetcher {
    private static let baseURL = URL(string: "https://app.devin.ai")!
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    #if os(macOS)
    private static let storageOrigin = "https://app.devin.ai"
    private static let externalOrgPrefix = "last-internal-org-for-external-org-v1-"

    /// Chromium 系浏览器导入顺序：先 Chrome，再回退其它 Chromium 浏览器（与 CodexBar 一致）。
    private static let preferredBrowsers: [Browser] = [.chrome]
    private static let fallbackBrowsers: [Browser] = [
        .chromeBeta, .chromeCanary, .edge, .edgeBeta, .edgeCanary,
        .brave, .braveBeta, .braveNightly, .vivaldi, .arc, .arcBeta, .arcCanary,
        .dia, .chatgptAtlas, .chromium, .helium,
    ]
    #endif

    // MARK: - 凭证存在性（便宜的本地检查）

    /// 是否配置了 Devin 手动 Bearer 令牌（token 路；优先）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        manualToken(env: env) != nil
    }

    /// 是否能从浏览器 localStorage 拿到 Devin 登录会话（cookie 路）。注意：会触发浏览器本地存储读取。
    public static func hasSession(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "devin", env: env) else {
            return false
        }
        #if os(macOS)
        return importSession() != nil
        #else
        return false
        #endif
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        let auth = try resolveAuth(env: env)
        return try await fetchQuotaUsage(auth: auth, session: session)
    }

    // MARK: - 鉴权解析（token 优先，再 cookie）

    struct RequestAuth {
        let bearerToken: String
        let organization: String?
        let internalOrganizationID: String?
    }

    static func resolveAuth(env: [String: String]) throws -> RequestAuth {
        // 1. token（env）优先。
        if let token = manualToken(env: env) {
            let org = normalizedOrganization(organizationOverride(env: env))
            return RequestAuth(
                bearerToken: token,
                organization: org,
                internalOrganizationID: internalOrganizationID(from: org))
        }

        // 2. cookie（浏览器 localStorage）。
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "devin", env: env) else {
            throw DevinUsageError.noSession
        }
        #if os(macOS)
        guard let session = importSession() else { throw DevinUsageError.noSession }
        let override = normalizedOrganization(organizationOverride(env: env))
        return RequestAuth(
            bearerToken: session.accessToken,
            organization: override ?? normalizedOrganization(session.organization),
            internalOrganizationID: session.internalOrganizationID)
        #else
        throw DevinUsageError.noSession
        #endif
    }

    /// 手动 Bearer 令牌：剥掉 `authorization:` / `bearer ` 前缀（源码 `manualAuth`）。
    static func manualToken(env: [String: String]) -> String? {
        var raw: String?
        for key in ["DEVIN_BEARER_TOKEN", "DEVIN_AUTHORIZATION"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                raw = v
                break
            }
        }
        guard var token = raw else { return nil }
        if token.lowercased().hasPrefix("authorization:") {
            if let idx = token.firstIndex(of: ":") {
                token = String(token[token.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token.isEmpty ? nil : token
    }

    static func organizationOverride(env: [String: String]) -> String? {
        for key in ["DEVIN_ORGANIZATION", "DEVIN_ORG"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        return nil
    }

    // MARK: - 配额接口

    private static func fetchQuotaUsage(auth: RequestAuth, session: URLSession) async throws -> CodexUsageSnapshot {
        guard let organization = normalizedOrganization(auth.organization) else {
            throw DevinUsageError.missingOrganization
        }

        var lastError: Error?
        for path in candidatePaths(organization: organization, internalOrganizationID: auth.internalOrganizationID) {
            do {
                let data = try await get(path: path, auth: auth, session: session)
                return try parse(data)
            } catch let error as DevinUsageError {
                lastError = error
                if case .unauthorized = error { throw error }
                continue
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? DevinUsageError.invalidResponse
    }

    private static func get(path: String, auth: RequestAuth, session: URLSession) async throws -> Data {
        let url = baseURL.appendingPathComponent("api/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(auth.bearerToken)", forHTTPHeaderField: "Authorization")
        if let internalOrganizationID = auth.internalOrganizationID {
            request.setValue(internalOrganizationID, forHTTPHeaderField: "x-cog-org-id")
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw DevinUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as DevinUsageError {
            throw e
        } catch {
            throw DevinUsageError.network(error.localizedDescription)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw DevinUsageError.unauthorized }
        guard http.statusCode == 200 else { throw DevinUsageError.server(http.statusCode) }
        return data
    }

    /// 组织路径的多种候选写法（源码 `candidatePaths`）。
    private static func candidatePaths(organization: String, internalOrganizationID: String?) -> [String] {
        var paths: [String] = []
        let normalized = normalizedOrganization(organization) ?? organization
        if let internalOrganizationID {
            paths.append("\(internalOrganizationID)/billing/quota/usage")
        }
        paths.append("\(normalized)/billing/quota/usage")
        if normalized.hasPrefix("org/") {
            let slug = String(normalized.dropFirst(4))
            paths.append("\(slug)/billing/quota/usage")
        }
        if !normalized.hasPrefix("org/"), !normalized.hasPrefix("organizations/") {
            paths.append("org/\(normalized)/billing/quota/usage")
        }
        if let internalOrganizationID {
            paths.append("organizations/\(internalOrganizationID)/billing/quota/usage")
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    // MARK: - 组织标准化（源码 `normalizedOrganization` / `isInternalOrganizationID`）

    static func normalizedOrganization(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value),
           let host = url.host?.lowercased(),
           host == "devin.ai" || host.hasSuffix(".devin.ai")
        {
            let components = url.path.split(separator: "/").map(String.init)
            if components.count >= 2, components[0] == "org" {
                value = "org/\(components[1])"
            } else if components.count >= 2, components[0] == "organizations" {
                value = "organizations/\(components[1])"
            }
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasPrefix("org/") || value.hasPrefix("organizations/") {
            return value
        }
        if isInternalOrganizationID(value) {
            return "organizations/\(value)"
        }
        return "org/\(value)"
    }

    private static func internalOrganizationID(from normalized: String?) -> String? {
        guard let normalized, normalized.hasPrefix("organizations/") else { return nil }
        return String(normalized.dropFirst("organizations/".count))
    }

    static func isInternalOrganizationID(_ value: String) -> Bool {
        value.hasPrefix("org-") || value.hasPrefix("org_")
    }

    // MARK: - 浏览器会话导入（cookie 路；源码 `DevinSessionImporter`）

    #if os(macOS)
    struct SessionInfo {
        let accessToken: String
        let organization: String?
        let internalOrganizationID: String?
    }

    static func importSession() -> SessionInfo? {
        if let s = importSession(browsers: preferredBrowsers) { return s }
        return importSession(browsers: fallbackBrowsers)
    }

    private static func importSession(browsers: [Browser]) -> SessionInfo? {
        let roots = ChromiumProfileLocator.roots(
            for: browsers,
            homeDirectories: BrowserCookieClient.defaultHomeDirectories())
        for root in roots {
            for levelDBURL in profileLevelDBDirs(root: root.url) {
                let storage = readLocalStorage(from: levelDBURL)
                guard let token = accessToken(from: storage) else { continue }
                let orgInfo = organizationInfo(from: storage)
                return SessionInfo(
                    accessToken: token,
                    organization: orgInfo.organization,
                    internalOrganizationID: orgInfo.internalOrganizationID)
            }
        }
        return nil
    }

    /// 找出某 Chromium profile root 下所有含 `Local Storage/leveldb` 的 profile 目录。
    private static func profileLevelDBDirs(root: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileDirs = entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return profileDirs.compactMap { dir in
            let levelDBURL = dir.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            return FileManager.default.fileExists(atPath: levelDBURL.path) ? levelDBURL : nil
        }
    }

    private static func readLocalStorage(from levelDBURL: URL) -> [String: String] {
        var storage: [String: String] = [:]
        let entries = ChromiumLocalStorageReader.readEntries(for: storageOrigin, in: levelDBURL)
        for entry in entries {
            storage[entry.key] = decodedStorageValue(entry.value)
        }
        let textEntries = ChromiumLocalStorageReader.readTextEntries(in: levelDBURL)
        for entry in textEntries where storage[entry.key] == nil {
            if isUsefulStorageKey(entry.key) {
                storage[entry.key] = decodedStorageValue(entry.value)
            }
        }
        return storage
    }

    private static func decodedStorageValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data)
        {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: token 提取（源码 `accessToken` / `findAuth1Token` / `findAccessToken`）

    private static func accessToken(from storage: [String: String]) -> String? {
        for (key, value) in storage where key.hasSuffix("auth1_session") {
            if let json = jsonObject(from: value), let token = findAuth1Token(in: json) {
                return token
            }
        }
        for (key, value) in storage where key.contains("auth0spajs@@::") {
            if let json = jsonObject(from: value), let token = findAccessToken(in: json) {
                return token
            }
        }
        for value in storage.values {
            if let json = jsonObject(from: value), let token = findAccessToken(in: json) {
                return token
            }
        }
        return nil
    }

    private static func jsonObject(from raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func findAuth1Token(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any],
              let token = dictionary["token"] as? String
        else { return nil }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("auth1_") && value.count > 20 ? value : nil
    }

    private static func findAccessToken(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["access_token", "accessToken"] {
                if let value = dictionary[key] as? String, looksLikeToken(value) {
                    return value
                }
            }
            for value in dictionary.values {
                if let found = findAccessToken(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findAccessToken(in: value) { return found }
            }
        }
        return nil
    }

    private static func looksLikeToken(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > 20 && (value.hasPrefix("eyJ") || value.contains("."))
    }

    private static func isUsefulStorageKey(_ key: String) -> Bool {
        key.hasSuffix("auth1_session") ||
            key.contains("auth0spajs@@::") ||
            key.contains(externalOrgPrefix) ||
            key.contains("post-auth-v") ||
            key.contains("member-info-v") ||
            key.contains("feature-flags-cache:org-") ||
            key.contains("feature-flags-cache:org_")
    }

    // MARK: 组织推断（源码 `organizationInfo` / `inferredOrganizationInfo`）

    private static func organizationInfo(from storage: [String: String])
        -> (organization: String?, internalOrganizationID: String?)
    {
        var firstInternalOrgID: String?
        for (key, value) in storage where key.contains(externalOrgPrefix) {
            let suffix = externalOrgSlug(from: key)
            let orgID = cleanedOrgID(value)
            if firstInternalOrgID == nil { firstInternalOrgID = orgID }
            if suffix != "null" {
                return ("org/\(suffix)", orgID)
            }
        }

        if let inferred = inferredOrganizationInfo(from: storage) {
            return inferred
        }

        return (firstInternalOrgID.map { "organizations/\($0)" }, firstInternalOrgID)
    }

    private static func inferredOrganizationInfo(from storage: [String: String])
        -> (organization: String?, internalOrganizationID: String?)?
    {
        var fallbackSlug: String?
        var fallbackInternalOrgID: String?
        for (key, value) in storage {
            let object = jsonObject(from: value)
            let internalOrgID = cleanedOrgID(firstString(
                in: object,
                matching: ["internalOrgId", "internal_org_id", "org_id", "orgId"]))
                ?? internalOrgIDFromStorageKey(key)
            let slug = cleanedSlug(
                slugFromPostAuthKey(key) ??
                    firstString(in: object, matching: ["orgName", "org_name", "externalOrgId", "external_org_id"]))
            if fallbackSlug == nil, let slug { fallbackSlug = slug }
            if fallbackInternalOrgID == nil, let internalOrgID { fallbackInternalOrgID = internalOrgID }
        }
        if let fallbackSlug {
            return ("org/\(fallbackSlug)", fallbackInternalOrgID)
        }
        if let fallbackInternalOrgID {
            return ("organizations/\(fallbackInternalOrgID)", fallbackInternalOrgID)
        }
        return nil
    }

    private static func externalOrgSlug(from key: String) -> String {
        guard let range = key.range(of: externalOrgPrefix) else { return key }
        return String(key[range.upperBound...])
    }

    private static func cleanedOrgID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = decodedStorageValue(raw)
        guard isInternalOrganizationID(value) else { return nil }
        return value
    }

    private static func cleanedSlug(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = decodedStorageValue(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "null", !isInternalOrganizationID(value) else { return nil }
        if value.hasPrefix("org/") { return String(value.dropFirst(4)) }
        return value
    }

    private static func slugFromPostAuthKey(_ key: String) -> String? {
        guard let range = key.range(of: "-org_name-") else { return nil }
        return String(key[range.upperBound...])
    }

    private static func internalOrgIDFromStorageKey(_ key: String) -> String? {
        guard let range = key.range(of: #"org[-_][A-Za-z0-9]{8,}"#, options: .regularExpression) else {
            return nil
        }
        return cleanedOrgID(String(key[range]))
    }

    private static func firstString(in object: Any?, matching keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let string = value as? String, !string.isEmpty {
                    return string
                }
                if let found = firstString(in: value, matching: keys) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = firstString(in: value, matching: keys) { return found }
            }
        }
        return nil
    }
    #endif

    // MARK: - 解析（源码 `DevinUsageParser`）

    static func parse(_ data: Data) throws -> CodexUsageSnapshot {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw DevinUsageError.invalidResponse }

        let current = (object as? [String: Any]).map(currentQuotaWindows)
        let daily = current?.daily ?? findWindow(in: object, matching: isDailyKey)
        let weekly = current?.weekly ?? findWindow(in: object, matching: isWeeklyKey)
        guard daily != nil || weekly != nil else { throw DevinUsageError.invalidResponse }

        let planType = findPlanName(in: object)
        let session = daily.map { makeWindow($0, fallbackSeconds: 24 * 60 * 60) }
        // 无周期信息（既无周窗也无周重置）时：weekly = nil（见文件头约定）。
        let weeklyWindow = weekly.map { makeWindow($0, fallbackSeconds: 7 * 24 * 60 * 60) }
        return CodexUsageSnapshot(planType: planType, session: session, weekly: weeklyWindow)
    }

    /// 一个限流窗：已用百分比（0...100）+ 重置时刻。
    private struct QuotaWindow {
        let usedPercent: Int
        let resetsAt: Date?
    }

    private static func makeWindow(_ window: QuotaWindow, fallbackSeconds: Int) -> CodexUsageSnapshot.Window {
        let reset = window.resetsAt ?? Date().addingTimeInterval(TimeInterval(30 * 24 * 60 * 60))
        let windowSeconds = window.resetsAt != nil ? max(0, Int(reset.timeIntervalSinceNow)) : 30 * 24 * 60 * 60
        return CodexUsageSnapshot.Window(
            usedPercent: max(0, min(100, window.usedPercent)),
            resetAt: reset,
            windowSeconds: windowSeconds == 0 ? fallbackSeconds : windowSeconds)
    }

    private static func currentQuotaWindows(_ dictionary: [String: Any])
        -> (daily: QuotaWindow?, weekly: QuotaWindow?)
    {
        let daily = currentQuotaWindow(
            percent: dictionary["daily_percentage"], resetsAt: dictionary["daily_reset_at"])
        let weekly = currentQuotaWindow(
            percent: dictionary["weekly_percentage"], resetsAt: dictionary["weekly_reset_at"])
        return (daily, weekly)
    }

    private static func currentQuotaWindow(percent: Any?, resetsAt: Any?) -> QuotaWindow? {
        guard let usedPercent = double(percent) else { return nil }
        let normalized = usedPercent <= 1 ? usedPercent * 100 : usedPercent
        return QuotaWindow(usedPercent: Int(normalized.rounded()), resetsAt: date(from: resetsAt))
    }

    private static func findWindow(in object: Any, matching keyMatches: (String) -> Bool) -> QuotaWindow? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where keyMatches(key) {
                if let window = window(from: value) { return window }
            }
            for value in dictionary.values {
                if let found = findWindow(in: value, matching: keyMatches) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findWindow(in: value, matching: keyMatches) { return found }
            }
        }
        return nil
    }

    private static func window(from object: Any) -> QuotaWindow? {
        guard let dictionary = object as? [String: Any] else {
            guard let percent = percent(from: object) else { return nil }
            return QuotaWindow(usedPercent: Int(percent.rounded()), resetsAt: nil)
        }
        if let percent = percent(from: dictionary) {
            return QuotaWindow(usedPercent: Int(percent.rounded()), resetsAt: findResetDate(in: dictionary))
        }
        if let nested = dictionary.values.lazy.compactMap({ window(from: $0) }).first {
            return nested
        }
        return nil
    }

    /// 已用百分比：直读 percent；否则 used/limit×100；否则 (limit-remaining)/limit×100。
    private static func percent(from object: Any) -> Double? {
        if let number = double(object) {
            return number <= 1 ? number * 100 : number
        }
        guard let dictionary = object as? [String: Any] else { return nil }

        let directKeys = [
            "used_percent", "usedPercent", "usage_percent", "usagePercent",
            "percent_used", "percentUsed", "percent",
        ]
        for key in directKeys {
            if let value = double(dictionary[key]) {
                return value <= 1 ? value * 100 : value
            }
        }
        let remainingKeys = ["remaining_percent", "remainingPercent", "percent_remaining", "percentRemaining"]
        for key in remainingKeys {
            if let value = double(dictionary[key]) {
                let p = value <= 1 ? value * 100 : value
                return 100 - p
            }
        }
        let used = firstDouble(in: dictionary, keys: ["used", "usage", "used_count", "usedCount", "consumed"])
        let limit = firstDouble(in: dictionary, keys: ["limit", "quota", "total", "max", "available"])
        if let used, let limit, limit > 0 {
            return used / limit * 100
        }
        let remaining = firstDouble(in: dictionary, keys: ["remaining", "left", "available"])
        if let remaining, let limit, limit > 0 {
            return (limit - remaining) / limit * 100
        }
        return nil
    }

    private static func findPlanName(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["plan_name", "planName", "plan", "tier", "subscription_tier", "subscriptionTier"] {
                if let value = dictionary[key] as? String, let cleaned = cleanDisplay(value) {
                    return cleaned
                }
            }
            for value in dictionary.values {
                if let found = findPlanName(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findPlanName(in: value) { return found }
            }
        }
        return nil
    }

    private static func findResetDate(in dictionary: [String: Any]) -> Date? {
        for (key, value) in dictionary where key.localizedCaseInsensitiveContains("reset") {
            if let d = date(from: value) { return d }
        }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        if let raw = value as? String {
            if let d = ISO8601DateFormatter().date(from: raw) { return d }
            if let number = Double(raw) { return date(from: number) }
        }
        if let number = double(value) { return date(from: number) }
        return nil
    }

    private static func date(from number: Double) -> Date? {
        guard number > 0 else { return nil }
        let seconds = number > 10_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    private static func firstDouble(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = double(dictionary[key]) { return value }
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func isDailyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("daily") || key.contains("day"))
    }

    private static func isWeeklyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("weekly") || key.contains("week"))
    }

    private static func cleanDisplay(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.split(separator: "_").flatMap { $0.split(separator: "-") }.map { part in
            part.prefix(1).uppercased() + String(part.dropFirst())
        }.joined(separator: " ")
    }
}
