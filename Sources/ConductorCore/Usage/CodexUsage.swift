import Foundation

/// Codex（ChatGPT 订阅）用量快照。取数路径与 CodexBar 相同：
/// 读 `~/.codex/auth.json`（或 `$CODEX_HOME/auth.json`）的 OAuth access token，
/// 调 `https://chatgpt.com/backend-api/wham/usage`，解析会话/周两个限流窗口。
public struct CodexUsageSnapshot: Sendable, Equatable {
    public let planType: String?
    /// 会话窗口（primary）。
    public let session: Window?
    /// 周窗口（secondary）。
    public let weekly: Window?

    public struct Window: Sendable, Equatable {
        /// 已用百分比 0...100。
        public let usedPercent: Int
        /// 重置时间。
        public let resetAt: Date
        /// 窗口总时长（秒）。
        public let windowSeconds: Int

        public init(usedPercent: Int, resetAt: Date, windowSeconds: Int) {
            self.usedPercent = usedPercent
            self.resetAt = resetAt
            self.windowSeconds = windowSeconds
        }

        public var remainingPercent: Int { max(0, 100 - usedPercent) }
    }

    public init(planType: String?, session: Window?, weekly: Window?) {
        self.planType = planType
        self.session = session
        self.weekly = weekly
    }

    public var isEmpty: Bool {
        session == nil && weekly == nil
    }

    public var allWindows: [(title: String, window: RateWindow)] {
        var out: [(String, RateWindow)] = []
        if let session {
            out.append((L("会话"), RateWindow(
                title: L("会话"),
                usedPercent: Double(session.usedPercent),
                windowMinutes: session.windowSeconds > 0 ? session.windowSeconds / 60 : nil,
                resetsAt: session.resetAt)))
        }
        if let weekly {
            out.append((L("本周"), RateWindow(
                title: L("本周"),
                usedPercent: Double(weekly.usedPercent),
                windowMinutes: weekly.windowSeconds > 0 ? weekly.windowSeconds / 60 : nil,
                resetsAt: weekly.resetAt)))
        }
        return out
    }

    public var providerCost: ProviderCostSnapshot? { nil }
}

public enum CodexUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case unauthorized
    case invalidResponse
    case server(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: L("未找到 Codex 登录信息，请先运行 `codex` 登录")
        case .unauthorized: L("Codex 令牌已过期，请重新运行 `codex` 登录")
        case .invalidResponse: L("Codex 用量接口返回异常")
        case let .server(code): L("Codex 接口错误（%ld）", code)
        case let .network(msg): L("网络错误：%@", msg)
        }
    }
}

public enum CodexUsageFetcher {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// 是否存在 Codex 登录凭证（用于决定账号用量区是否展示该 provider）。
    public static func hasCredentials(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        FileManager.default.fileExists(atPath: authFileURL(env: env).path)
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        let creds = try loadCredentials(env: env)

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Conductor", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = creds.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw CodexUsageError.invalidResponse }
            data = d
            http = h
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.network(error.localizedDescription)
        }

        switch http.statusCode {
        case 200...299:
            do {
                return try parse(data)
            } catch {
                throw CodexUsageError.invalidResponse
            }
        case 401, 403:
            throw CodexUsageError.unauthorized
        default:
            throw CodexUsageError.server(http.statusCode)
        }
    }

    // MARK: - 凭证

    struct Credentials {
        let accessToken: String
        let accountId: String?
    }

    static func authFileURL(env: [String: String]) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty
        {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex").appendingPathComponent("auth.json")
    }

    static func loadCredentials(env: [String: String]) throws -> Credentials {
        let url = authFileURL(env: env)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { throw CodexUsageError.notLoggedIn }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }

        // 纯 API key 模式
        if let apiKey = (json["OPENAI_API_KEY"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty
        {
            return Credentials(accessToken: apiKey, accountId: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any] else { throw CodexUsageError.notLoggedIn }
        let access = (tokens["access_token"] as? String) ?? (tokens["accessToken"] as? String)
        guard let accessToken = access, !accessToken.isEmpty else { throw CodexUsageError.notLoggedIn }
        let accountId = (tokens["account_id"] as? String) ?? (tokens["accountId"] as? String)
        return Credentials(accessToken: accessToken, accountId: accountId)
    }

    // MARK: - 解析

    static func parse(_ data: Data) throws -> CodexUsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }
        let plan = json["plan_type"] as? String
        let rate = json["rate_limit"] as? [String: Any]
        return CodexUsageSnapshot(
            planType: plan,
            session: window(from: rate?["primary_window"] as? [String: Any]),
            weekly: window(from: rate?["secondary_window"] as? [String: Any]))
    }

    private static func window(from dict: [String: Any]?) -> CodexUsageSnapshot.Window? {
        guard let dict else { return nil }
        guard let used = intValue(dict["used_percent"]),
              let resetAt = intValue(dict["reset_at"])
        else { return nil }
        let windowSeconds = intValue(dict["limit_window_seconds"]) ?? 0
        return CodexUsageSnapshot.Window(
            usedPercent: max(0, min(100, used)),
            resetAt: Date(timeIntervalSince1970: TimeInterval(resetAt)),
            windowSeconds: windowSeconds)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String { return Int(Double(s) ?? 0) }
        return nil
    }
}
