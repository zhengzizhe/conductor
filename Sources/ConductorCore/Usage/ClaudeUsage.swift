import Foundation
#if canImport(Security)
import Security
#endif

/// Claude（Claude Code 订阅）用量取数。取数路径与 CodexBar 的 OAuth 路一致：
/// 读 `~/.claude/.credentials.json`（或 Keychain `Claude Code-credentials`）里的
/// `claudeAiOauth.accessToken`，调 `https://api.anthropic.com/api/oauth/usage`，
/// 解析 5 小时会话窗口、7 天周窗口、模型专属周窗与 Daily Routines 等附加窗口，
/// 以及 `extra_usage`（额外用量月度消费 vs 上限）。
///
/// 产出富模型 `UsageSnapshot`：session→primary、weekly→secondary、模型专属周窗→tertiary，
/// Daily Routines 等→extraRateWindows，extra_usage→providerCost。
public enum ClaudeUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case unauthorized
    case invalidResponse
    case server(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: L("未找到 Claude 登录信息，请先运行 `claude` 登录")
        case .unauthorized: L("Claude 令牌已过期，请重新运行 `claude` 登录")
        case .invalidResponse: L("Claude 用量接口返回异常")
        case let .server(code): L("Claude 接口错误（%ld）", code)
        case let .network(msg): L("网络错误：%@", msg)
        }
    }
}

public enum ClaudeUsageFetcher {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let fallbackVersion = "2.1.0"
    private static let sessionWindowSeconds = 5 * 60 * 60
    private static let weeklyWindowSeconds = 7 * 24 * 60 * 60

    /// 是否存在 Claude 登录凭证（文件或 Keychain）。Keychain 只查条目存在、不取密钥数据，不弹授权框。
    public static func hasCredentials(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if FileManager.default.fileExists(atPath: credentialsFileURL(env: env).path) { return true }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        userAgentVersion: String? = nil,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        let creds = try loadCredentials(env: env)

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        let version = userAgentVersion ?? fallbackVersion
        request.setValue("claude-code/\(version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw ClaudeUsageError.invalidResponse }
            data = d
            http = h
        } catch let error as ClaudeUsageError {
            throw error
        } catch {
            throw ClaudeUsageError.network(error.localizedDescription)
        }

        switch http.statusCode {
        case 200...299:
            do {
                return try parse(data, planType: creds.subscriptionType)
            } catch {
                throw ClaudeUsageError.invalidResponse
            }
        case 401, 403:
            throw ClaudeUsageError.unauthorized
        default:
            throw ClaudeUsageError.server(http.statusCode)
        }
    }

    // MARK: - 凭证

    struct Credentials {
        let accessToken: String
        let subscriptionType: String?
    }

    static func credentialsFileURL(env: [String: String]) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let configDir = env["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configDir.isEmpty
        {
            return URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json")
        }
        return home.appendingPathComponent(".claude").appendingPathComponent(".credentials.json")
    }

    static func loadCredentials(env: [String: String]) throws -> Credentials {
        // 1) 凭证文件（多数 Linux / 部分 macOS 安装）
        if let data = try? Data(contentsOf: credentialsFileURL(env: env)),
           let creds = parseCredentials(data)
        {
            return creds
        }
        if shouldAvoidKeychain(env: env) {
            throw ClaudeUsageError.notLoggedIn
        }
        // 2) macOS Keychain（Claude Code 默认存这里）。读取他人 keychain 项可能弹一次授权框。
        #if canImport(Security)
        if let data = keychainCredentialData(), let creds = parseCredentials(data) {
            return creds
        }
        #endif
        throw ClaudeUsageError.notLoggedIn
    }

    static func shouldAvoidKeychain(env: [String: String]) -> Bool {
        let raw = env["CONDUCTOR_CLAUDE_AVOID_KEYCHAIN"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// 解析 `{ "claudeAiOauth": { "accessToken": ..., "subscriptionType": ... } }`。
    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }
        let token = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String)
        guard let accessToken = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else { return nil }
        let sub = (oauth["subscriptionType"] as? String) ?? (oauth["subscription_type"] as? String)
        return Credentials(accessToken: accessToken, subscriptionType: sub)
    }

    #if canImport(Security)
    private static func keychainCredentialData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }
    #endif

    // MARK: - 解析

    static func parse(_ data: Data, planType: String?) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.invalidResponse
        }

        // 取窗口字典：按 CodexBar 的多键回退顺序找第一个存在的键。
        func firstDict(_ keys: [String]) -> [String: Any]? {
            for key in keys {
                if let dict = json[key] as? [String: Any] { return dict }
            }
            return nil
        }

        // 5 小时会话窗（primary）。CodexBar 在缺 five_hour 时会回退到各 7 天窗，
        // 但 conductor 这里以 session→primary、seven_day→secondary 的位置语义为准，
        // 故 primary 仅取 five_hour。
        let session = window(
            from: json["five_hour"] as? [String: Any],
            title: L("会话"),
            windowSeconds: sessionWindowSeconds)
        // 每周全模型窗（secondary）。
        let weekly = window(
            from: json["seven_day"] as? [String: Any],
            title: L("本周"),
            windowSeconds: weeklyWindowSeconds)
        // 模型专属周窗（tertiary）：Sonnet 优先，其次 Opus。
        let modelSpecificDict = (json["seven_day_sonnet"] as? [String: Any])
        let isOpus = modelSpecificDict == nil
        let modelSpecific = window(
            from: modelSpecificDict ?? (json["seven_day_opus"] as? [String: Any]),
            title: isOpus ? L("Opus 周") : L("Sonnet 周"),
            windowSeconds: weeklyWindowSeconds)

        // 附加命名窗口（Daily Routines 等）。
        let routinesDict = firstDict([
            "seven_day_routines",
            "seven_day_claude_routines",
            "claude_routines",
            "routines",
            "routine",
            "seven_day_cowork",
            "cowork",
        ])
        var extras: [NamedRateWindow] = []
        if let routines = routinesDict, let w = window(
            from: routines,
            title: L("Daily Routines"),
            windowSeconds: weeklyWindowSeconds)
        {
            extras.append(NamedRateWindow(id: "claude-routines", title: L("Daily Routines"), window: w))
        }

        // 额外用量（extra_usage）→ providerCost（月度消费 vs 上限，单位为分，需除以 100）。
        let providerCost = extraUsageCost(json["extra_usage"] as? [String: Any])

        // 至少要有一个时间窗或消费数据才算有效，否则视为接口异常。
        guard session != nil || weekly != nil || modelSpecific != nil
            || !extras.isEmpty || providerCost != nil
        else { throw ClaudeUsageError.invalidResponse }

        return UsageSnapshot(
            primary: session,
            secondary: weekly,
            tertiary: modelSpecific,
            extraRateWindows: extras,
            providerCost: providerCost,
            planName: planType)
    }

    private static func window(
        from dict: [String: Any]?,
        title: String,
        windowSeconds: Int) -> RateWindow?
    {
        guard let dict, let utilization = doubleValue(dict["utilization"]) else { return nil }
        let resetAt = parseISO8601(dict["resets_at"] as? String)
            ?? Date().addingTimeInterval(TimeInterval(windowSeconds))
        return RateWindow(
            title: title,
            usedPercent: utilization,
            windowMinutes: windowSeconds / 60,
            resetsAt: resetAt)
    }

    /// 解析 `extra_usage`：`is_enabled` 为真且有 `used_credits` / `monthly_limit` 时，
    /// 产出月度消费快照。OAuth 接口的金额是「分」，统一除以 100 转成主单位（美元）。
    private static func extraUsageCost(_ dict: [String: Any]?) -> ProviderCostSnapshot? {
        guard let dict, (dict["is_enabled"] as? Bool) == true,
              let usedCents = doubleValue(dict["used_credits"]),
              let limitCents = doubleValue(dict["monthly_limit"])
        else { return nil }
        let rawCurrency = (dict["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = (rawCurrency?.isEmpty ?? true) ? "USD" : rawCurrency!
        return ProviderCostSnapshot(
            used: usedCents / 100.0,
            limit: limitCents / 100.0,
            currencyCode: currency,
            period: L("本月"))
    }

    static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }
}
