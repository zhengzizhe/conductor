import Foundation

/// Groq（GroqCloud）用量取数。摘自 CodexBar `Groq` provider，自足、只依赖 API key：
/// 用 `GROQ_API_KEY` 走 `Bearer` 调 Groq 的 Prometheus 指标端点
/// `https://api.groq.com/v1/metrics/prometheus/api/v1/query`，
/// 分别查询 requests / tokens_in / tokens_out / prompt_cache_hits 的 5 分钟速率（rate5m）。
///
/// 注意：Groq 指标 API 返回的是「每秒速率」，没有配额/限额，因此无法算「已用百分比」。
/// CodexBar 原实现里 `usedPercent` 恒为 0，这里忠实照搬：session 窗口 usedPercent=0、
/// reset=now+30 天，weekly 为空。
///
/// 环境变量：`GROQ_API_KEY`（必需）、`GROQ_API_URL`（可选，覆盖端点，需 HTTPS 或裸主机名）。
public enum GroqUsageError: LocalizedError, Sendable {
    case missingCredentials
    case invalidURL
    case invalidEndpointOverride
    case accessDenied(String)
    case apiError(String)
    case parseFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: L("未找到 Groq 令牌，请设置环境变量 GROQ_API_KEY")
        case .invalidURL: L("Groq 指标 URL 无效")
        case .invalidEndpointOverride: L("GROQ_API_URL 必须使用 HTTPS 或裸主机名")
        case let .accessDenied(m): L("Groq 指标访问被拒绝：%@", m)
        case let .apiError(m): L("Groq 指标 API 错误：%@", m)
        case let .parseFailed(m): L("Groq 指标解析失败：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum GroqUsageFetcher {
    private static let apiKeyEnvironmentKey = "GROQ_API_KEY"
    private static let apiURLEnvironmentKey = "GROQ_API_URL"
    private static let defaultAPIURL = "https://api.groq.com/v1"

    /// 是否配置了 Groq 令牌（用于在工具面板里把 Groq 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        clean(env[apiKeyEnvironmentKey])
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// 解析 `GROQ_API_URL` 覆盖（无显式 scheme 时补 https://），并校验只接受 HTTPS、无 user/password。
    static func normalizedHTTPSURL(from raw: String) -> URL? {
        let url: URL? = hasExplicitURLScheme(raw) ? URL(string: raw) : URL(string: "https://\(raw)")
        guard let url else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        guard let host = url.host?.lowercased(),
              !host.isEmpty,
              !host.contains("%"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return url
    }

    private static func hasExplicitURLScheme(_ raw: String) -> Bool {
        guard let colonIndex = raw.firstIndex(of: ":") else { return false }
        if raw[colonIndex...].hasPrefix("://") { return true }
        if let authorityEnd = raw.firstIndex(where: { ["/", "?", "#"].contains($0) }),
           colonIndex > authorityEnd
        {
            return false
        }
        let afterColon = raw.index(after: colonIndex)
        guard afterColon < raw.endIndex else { return true }
        let portEnd = raw[afterColon...].firstIndex { Set<Character>(["/", "?", "#"]).contains($0) } ?? raw.endIndex
        let suffix = raw[afterColon..<portEnd]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return false }
        let scheme = raw[..<colonIndex]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || ["+", "-", "."].contains($0) }
    }

    static func apiURL(env: [String: String]) throws -> URL {
        guard let raw = clean(env[apiURLEnvironmentKey]) else {
            return URL(string: defaultAPIURL)!
        }
        guard let override = normalizedHTTPSURL(from: raw) else {
            throw GroqUsageError.invalidEndpointOverride
        }
        return override
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw GroqUsageError.missingCredentials }

        let baseURL = try apiURL(env: env)
            .appendingPathComponent("metrics")
            .appendingPathComponent("prometheus")

        async let requests = queryScalar(
            query: "sum(model_project_id_status_code:requests:rate5m)",
            apiKey: apiKey, baseURL: baseURL, session: session)
        async let inputTokens = queryScalar(
            query: "sum(model_project_id:tokens_in:rate5m)",
            apiKey: apiKey, baseURL: baseURL, session: session)
        async let outputTokens = queryScalar(
            query: "sum(model_project_id:tokens_out:rate5m)",
            apiKey: apiKey, baseURL: baseURL, session: session)
        async let cacheHits = queryScalar(
            query: "sum(model_project_id:prompt_cache_hits:rate5m)",
            apiKey: apiKey, baseURL: baseURL, session: session)

        // 速率（每秒）→ 仅作展示用，无配额可算百分比。
        _ = try await (requests, inputTokens, outputTokens, cacheHits)

        // 无周期/配额：以 session 窗口返回，已用 0%，重置时间取 now+30 天，weekly 为空。
        let window = CodexUsageSnapshot.Window(
            usedPercent: 0,
            resetAt: Date().addingTimeInterval(30 * 86400),
            windowSeconds: 0)
        return CodexUsageSnapshot(planType: nil, session: window, weekly: nil)
    }

    // MARK: - 查询

    private static func queryScalar(
        query: String,
        apiKey: String,
        baseURL: URL,
        session: URLSession) async throws -> Double
    {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/query"),
            resolvingAgainstBaseURL: false)
        else { throw GroqUsageError.invalidURL }
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else { throw GroqUsageError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw GroqUsageError.parseFailed("non-HTTP response") }
            data = d
            http = h
        } catch let e as GroqUsageError {
            throw e
        } catch {
            throw GroqUsageError.network(error.localizedDescription)
        }

        guard (200..<300).contains(http.statusCode) else {
            let summary = responseSummary(data)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw GroqUsageError.accessDenied(summary)
            }
            throw GroqUsageError.apiError("HTTP \(http.statusCode): \(summary)")
        }
        return try parseScalar(data: data)
    }

    // MARK: - 解析

    private struct PrometheusResponse: Decodable {
        struct Payload: Decodable {
            let result: [Series]
        }

        struct Series: Decodable {
            let value: [PrometheusValue]?
        }

        enum PrometheusValue: Decodable {
            case number(Double)
            case string(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Double.self) {
                    self = .number(number)
                    return
                }
                self = try .string(container.decode(String.self))
            }

            var doubleValue: Double? {
                switch self {
                case let .number(number): number
                case let .string(text): Double(text)
                }
            }
        }

        let status: String
        let data: Payload?
        let error: String?
    }

    private static func parseScalar(data: Data) throws -> Double {
        do {
            let decoded = try JSONDecoder().decode(PrometheusResponse.self, from: data)
            guard decoded.status == "success" else {
                throw GroqUsageError.apiError(decoded.error ?? "query failed")
            }
            return decoded.data?.result.compactMap { series in
                series.value?.last?.doubleValue
            }.reduce(0, +) ?? 0
        } catch let error as GroqUsageError {
            throw error
        } catch {
            throw GroqUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}
