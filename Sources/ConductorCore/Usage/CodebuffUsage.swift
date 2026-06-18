import Foundation

/// Codebuff（前身 manicode）用量取数。忠实转写自 CodexBar 的 `Codebuff` provider，
/// 走 token（非 cookie）路径：优先环境变量 `CODEBUFF_API_KEY`，否则读本地
/// `~/.config/manicode/credentials.json`（`codebuff login` 写入）的 authToken。
///
/// 取数：用 Bearer token 对 `https://www.codebuff.com`
/// - POST `/api/v1/usage`（body `{"fingerprintId": ...}`）拿 credits 余额；
/// - GET `/api/user/subscription` 拿订阅/周限额（仅在凭证来自本地文件时附带请求，与 CodexBar 一致）。
///
/// credits 余额映射主窗（会话位）：used/total*100；total 缺失则用 used+remaining 推算。
/// 订阅 rateLimit 的 weekly 映射次窗（周位）。无任何周期信息时：主窗 reset 回退 now+30 天、weekly=nil。
///
/// 环境变量：`CODEBUFF_API_KEY`（可选）、`CODEBUFF_API_URL`（可选覆盖，需 HTTPS 或裸主机名）。
public enum CodebuffUsageError: LocalizedError, Sendable {
    case missingCredentials
    case unauthorized
    case endpointNotFound
    case serviceUnavailable(Int)
    case apiError(Int)
    case network(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            L("未找到 Codebuff 令牌，请设置环境变量 CODEBUFF_API_KEY，或运行 `codebuff login` 写入 ~/.config/manicode/credentials.json")
        case .unauthorized: L("Codebuff 登录态已失效，请重新登录 Codebuff")
        case .endpointNotFound: L("Codebuff 用量接口未找到")
        case let .serviceUnavailable(code): L("Codebuff 接口暂不可用（%ld）", code)
        case let .apiError(code): L("Codebuff 接口错误（%ld）", code)
        case let .network(msg): L("网络错误：%@", msg)
        case let .parseFailed(msg): L("Codebuff 用量解析失败：%@", msg)
        }
    }
}

public enum CodebuffUsageFetcher {
    private static let apiTokenKey = "CODEBUFF_API_KEY"
    private static let defaultBaseURL = "https://www.codebuff.com"
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// 是否配置了 Codebuff 令牌（环境变量或本地凭证文件）。便宜的本地检查，不发网络。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        resolveToken(env: env) != nil
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let resolution = resolveToken(env: env) else { throw CodebuffUsageError.missingCredentials }
        try validateEndpointOverride(env: env)
        let baseURL = apiURL(env: env)

        // CodexBar：仅当凭证来自本地文件时附带订阅请求（env token 不带）。
        let usage = try await fetchUsagePayload(apiKey: resolution.token, baseURL: baseURL, session: session)
        var subscription: SubscriptionPayload?
        if resolution.fromAuthFile {
            subscription = try? await fetchSubscriptionPayload(
                apiKey: resolution.token, baseURL: baseURL, session: session)
        }

        return makeSnapshot(usage: usage, subscription: subscription)
    }

    // MARK: - 凭证

    private struct TokenResolution {
        let token: String
        /// true 表示取自本地凭证文件（决定是否附带订阅请求）。
        let fromAuthFile: Bool
    }

    private static func resolveToken(env: [String: String]) -> TokenResolution? {
        if let token = clean(env[apiTokenKey]) {
            return TokenResolution(token: token, fromAuthFile: false)
        }
        if let token = authToken() {
            return TokenResolution(token: token, fromAuthFile: true)
        }
        return nil
    }

    /// 读 `~/.config/manicode/credentials.json` 的 `default.authToken` 或顶层 `authToken`。
    static func authToken(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let fileURL = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("manicode", isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(CredentialsFile.self, from: data)
        else { return nil }
        return clean(payload.default?.authToken) ?? clean(payload.authToken)
    }

    private struct CredentialsFile: Decodable {
        let `default`: CredentialsProfile?
        let authToken: String?
    }

    private struct CredentialsProfile: Decodable {
        let authToken: String?
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    // MARK: - 端点

    static func apiURL(env: [String: String]) -> URL {
        if let raw = clean(env["CODEBUFF_API_URL"]), let override = normalizedHTTPSURL(from: raw) {
            return override
        }
        return URL(string: defaultBaseURL)!
    }

    static func validateEndpointOverride(env: [String: String]) throws {
        guard let raw = clean(env["CODEBUFF_API_URL"]) else { return }
        guard normalizedHTTPSURL(from: raw) == nil else { return }
        throw CodebuffUsageError.network("CODEBUFF_API_URL 必须是 HTTPS 或裸主机名")
    }

    /// 接受 `https://host[/path]` 或裸主机名（补全为 https），拒绝非 HTTPS。
    private static func normalizedHTTPSURL(from raw: String) -> URL? {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            return scheme == "https" ? url : nil
        }
        return URL(string: "https://\(raw)")
    }

    // MARK: - 网络

    private static func fetchUsagePayload(
        apiKey: String, baseURL: URL, session: URLSession) async throws -> UsagePayload
    {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/usage"))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fingerprintId": "conductor-usage"])

        let data = try await send(request: request, session: session)
        return try parseUsagePayload(data)
    }

    private static func fetchSubscriptionPayload(
        apiKey: String, baseURL: URL, session: URLSession) async throws -> SubscriptionPayload
    {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/user/subscription"))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await send(request: request, session: session)
        return try parseSubscriptionPayload(data)
    }

    private static func send(request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw CodebuffUsageError.network("响应异常") }
            data = d
            http = h
        } catch let e as CodebuffUsageError {
            throw e
        } catch {
            throw CodebuffUsageError.network(error.localizedDescription)
        }
        if let err = statusError(for: http.statusCode) { throw err }
        guard http.statusCode == 200 else { throw CodebuffUsageError.apiError(http.statusCode) }
        return data
    }

    static func statusError(for statusCode: Int) -> CodebuffUsageError? {
        switch statusCode {
        case 401, 403: .unauthorized
        case 404: .endpointNotFound
        case 500...599: .serviceUnavailable(statusCode)
        default: nil
        }
    }

    // MARK: - 解析

    struct UsagePayload {
        let used: Double?
        let total: Double?
        let remaining: Double?
        let nextQuotaReset: Date?
    }

    struct SubscriptionPayload {
        let tier: String?
        let weeklyUsed: Double?
        let weeklyLimit: Double?
        let weeklyResetsAt: Date?
    }

    static func parseUsagePayload(_ data: Data) throws -> UsagePayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodebuffUsageError.parseFailed("Invalid JSON")
        }
        return UsagePayload(
            used: double(from: root["usage"]) ?? double(from: root["used"]),
            total: double(from: root["quota"]) ?? double(from: root["limit"]),
            remaining: double(from: root["remainingBalance"]) ?? double(from: root["remaining"]),
            nextQuotaReset: date(from: root["next_quota_reset"]))
    }

    static func parseSubscriptionPayload(_ data: Data) throws -> SubscriptionPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodebuffUsageError.parseFailed("Invalid JSON")
        }
        let subscription = root["subscription"] as? [String: Any]
        let rateLimit = root["rateLimit"] as? [String: Any]

        let tier = string(from: subscription?["displayName"])
            ?? string(from: root["displayName"])
            ?? string(from: subscription?["tier"])
            ?? string(from: root["tier"])
            ?? string(from: subscription?["scheduledTier"])
        let weeklyUsed = double(from: rateLimit?["weeklyUsed"]) ?? double(from: rateLimit?["used"])
        let weeklyLimit = double(from: rateLimit?["weeklyLimit"]) ?? double(from: rateLimit?["limit"])
        let weeklyResetsAt = date(from: rateLimit?["weeklyResetsAt"])

        return SubscriptionPayload(
            tier: tier,
            weeklyUsed: weeklyUsed,
            weeklyLimit: weeklyLimit,
            weeklyResetsAt: weeklyResetsAt)
    }

    // MARK: - 映射到 UsageSnapshot

    /// Codebuff 是 credits 模型：credits 余额 → providerCost（used/total credits），
    /// 订阅 rateLimit 周限额 → secondary（周窗）。无第三窗。planName 取订阅 tier。
    static func makeSnapshot(usage: UsagePayload, subscription: SubscriptionPayload?) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: makeWeeklyWindow(subscription),
            tertiary: nil,
            providerCost: makeCreditsCost(usage),
            planName: subscription?.tier)
    }

    /// credits 余额 → providerCost。used = 已用 credits、limit = 总 credits（缺失时用 used+remaining 推算）。
    /// 货币代码用 "Credits"；周期沿用 CodexBar 的会话位标签 "Credits"。total 缺失但有部分数据时按全额耗尽暴露。
    private static func makeCreditsCost(_ usage: UsagePayload) -> ProviderCostSnapshot? {
        let total = resolvedTotal(usage)
        guard let total, total > 0 else {
            // 无可用总额但有部分数据：按全额耗尽（used == limit）暴露，避免渲染误导性的健康进度条。
            if let used = usage.used {
                return ProviderCostSnapshot(
                    used: max(0, used),
                    limit: max(0, used),
                    currencyCode: "Credits",
                    period: "Credits",
                    resetsAt: usage.nextQuotaReset)
            }
            if let remaining = usage.remaining {
                let used = max(0, remaining)
                return ProviderCostSnapshot(
                    used: used,
                    limit: used,
                    currencyCode: "Credits",
                    period: "Credits",
                    resetsAt: usage.nextQuotaReset)
            }
            return nil
        }
        let used = resolvedUsed(usage, total: total)
        return ProviderCostSnapshot(
            used: used,
            limit: total,
            currencyCode: "Credits",
            period: "Credits",
            resetsAt: usage.nextQuotaReset)
    }

    /// 订阅 rateLimit 的周限额 → 次窗。无 limit 则 secondary=nil。
    private static func makeWeeklyWindow(_ subscription: SubscriptionPayload?) -> RateWindow? {
        guard let limit = subscription?.weeklyLimit, limit > 0 else { return nil }
        let used = max(0, subscription?.weeklyUsed ?? 0)
        let percent = min(100, max(0, (used / limit) * 100))
        return RateWindow(
            title: L("本周"),
            usedPercent: percent,
            windowMinutes: 7 * 24 * 60,
            resetsAt: subscription?.weeklyResetsAt)
    }

    private static func resolvedTotal(_ usage: UsagePayload) -> Double? {
        if let total = usage.total { return max(0, total) }
        if let used = usage.used, let remaining = usage.remaining { return max(0, used + remaining) }
        return nil
    }

    private static func resolvedUsed(_ usage: UsagePayload, total: Double) -> Double {
        if let used = usage.used { return max(0, used) }
        if let remaining = usage.remaining { return max(0, total - remaining) }
        return 0
    }

    // MARK: - 值解析

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            return raw.isFinite ? raw : nil
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let raw = Double(trimmed), raw.isFinite else { return nil }
            return raw
        default:
            return nil
        }
    }

    private static func string(from value: Any?) -> String? {
        switch value {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.doubleValue.isFinite ? number.stringValue : nil
        default:
            return nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: trimmed) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: trimmed) { return date }
            if let interval = Double(trimmed), interval.isFinite { return dateFromNumeric(interval) }
            return nil
        case let number as NSNumber:
            let raw = number.doubleValue
            return raw.isFinite ? dateFromNumeric(raw) : nil
        default:
            return nil
        }
    }

    private static func dateFromNumeric(_ value: Double) -> Date? {
        if value > 10_000_000_000 { return Date(timeIntervalSince1970: value / 1000) }
        return Date(timeIntervalSince1970: value)
    }
}
