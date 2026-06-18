import Foundation

/// Doubao（豆包 / 火山方舟 Ark）用量取数。忠实转写自 CodexBar `Doubao` provider 的 token 路径，自足、不依赖 cookie：
/// 用 `ARK_API_KEY`（或 `VOLCENGINE_API_KEY` / `DOUBAO_API_KEY`）走 `Bearer` 向方舟 coding 端点
/// 发一条 1 token 的探针请求，从响应头 `x-ratelimit-*` 解析「请求额度」窗口。账号级（与具体 CLI 无关）。
///
/// 说明：方舟没有专门的用量查询接口，只能借「发一次小请求」来探测限流头。CodexBar 依次尝试多个
/// 模型（不同 key 的可用模型不同），并对「200 但 remaining=0」这种含糊状态做二次确认。两端点皆 200/429
/// 都视为 key 有效。本机无 token，无法实跑验证。
///
/// 环境变量：`ARK_API_KEY` / `VOLCENGINE_API_KEY` / `DOUBAO_API_KEY`（任一，必需）。
public enum DoubaoUsageError: LocalizedError, Sendable {
    case missingCredentials
    case network(String)
    case apiError(Int, String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: L("未找到 Doubao(火山方舟) 令牌，请设置环境变量 ARK_API_KEY")
        case let .network(m): L("网络错误：%@", m)
        case let .apiError(code, m): L("Doubao 接口错误（%1$ld）：%2$@", code, m)
        case let .parseFailed(m): L("Doubao 用量解析失败：%@", m)
        }
    }
}

public enum DoubaoUsageFetcher {
    private static let apiURL = URL(string: "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions")!

    /// 待探测的模型，按可用概率排序。不同 key 可访问的模型不同，故依次尝试。
    private static let probeModels = [
        "doubao-seed-2.0-code",
        "doubao-1.5-pro-32k",
        "doubao-lite-32k",
    ]

    /// 是否配置了 Doubao 令牌（用于在工具面板里把 Doubao 视作「可用」）。便宜的本地检查，不发网络。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        for key in ["ARK_API_KEY", "VOLCENGINE_API_KEY", "DOUBAO_API_KEY"] {
            if let v = clean(env[key]) { return v }
        }
        return nil
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }

    // MARK: - 取数

    /// 一次探针的结果：解析出的限额快照 + HTTP 状态码。
    private struct Probe {
        let remaining: Int
        let limit: Int
        let resetTime: Date?
        let keyValid: Bool
        let requestLimitsReliable: Bool
        let statusCode: Int

        /// 「200 且额度可信、limit>0、remaining=0」的含糊耗尽态，需要二次确认。
        var hasAmbiguousZeroRemaining: Bool {
            statusCode == 200 && requestLimitsReliable && limit > 0 && remaining == 0
        }
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw DoubaoUsageError.missingCredentials }

        var lastError: Error?
        for model in probeModels {
            do {
                let result = try await probe(apiKey: apiKey, model: model, session: session)
                guard result.hasAmbiguousZeroRemaining else {
                    return snapshot(from: result)
                }
                let confirmed = try await confirmAmbiguousZeroRemaining(
                    initial: result, apiKey: apiKey, model: model, session: session)
                return snapshot(from: confirmed)
            } catch let error as DoubaoUsageError {
                // 404/403 表示这把 key 无权访问该模型 → 换下一个模型再试。
                if case let .apiError(code, _) = error, code == 404 || code == 403 {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? DoubaoUsageError.apiError(0, "All probe models failed")
    }

    /// 对含糊耗尽态做二次确认：再发一次探针。429 视为确认耗尽；两次都 200+remaining=0
    /// 则认定限流头不可信（额度窗口作废）。
    private static func confirmAmbiguousZeroRemaining(
        initial: Probe,
        apiKey: String,
        model: String,
        session: URLSession) async throws -> Probe
    {
        do {
            let confirmation = try await probe(apiKey: apiKey, model: model, session: session)
            if confirmation.statusCode == 429 {
                return confirmation.requestLimitsReliable ? confirmation : initial
            }
            guard confirmation.hasAmbiguousZeroRemaining else {
                return confirmation
            }
            // 两次 200 都 limit>0/remaining=0：把请求限额头视作不可信。
            return Probe(
                remaining: confirmation.remaining,
                limit: confirmation.limit,
                resetTime: confirmation.resetTime,
                keyValid: confirmation.keyValid,
                requestLimitsReliable: false,
                statusCode: confirmation.statusCode)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw error
            }
            // 确认失败：保留初始耗尽态。
            return initial
        }
    }

    private static func probe(
        apiKey: String,
        model: String,
        session: URLSession) async throws -> Probe
    {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]] as [[String: Any]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else {
                throw DoubaoUsageError.parseFailed("non-HTTP response")
            }
            data = d
            http = h
        } catch let e as DoubaoUsageError {
            throw e
        } catch {
            throw DoubaoUsageError.network(error.localizedDescription)
        }

        // 200（成功）与 429（限流）都带限流头，皆接受；其余视为错误。
        guard http.statusCode == 200 || http.statusCode == 429 else {
            throw DoubaoUsageError.apiError(http.statusCode, apiErrorSummary(statusCode: http.statusCode, data: data))
        }

        let headers = http.allHeaderFields
        let remaining = intHeader(headers, "x-ratelimit-remaining-requests")
        let limit = intHeader(headers, "x-ratelimit-limit-requests")
        let resetTime = stringHeader(headers, "x-ratelimit-reset-requests").flatMap(parseResetTime)

        // 200 或 429 都表示 key 有效（429 是被限流而非鉴权失败）。
        let keyValid = http.statusCode == 200 || http.statusCode == 429
        // 429 上只要有 limit 头就能判定请求桶耗尽；200 则要求 limit 与 remaining 同时存在。
        let requestLimitsReliable = http.statusCode == 429
            ? limit != nil
            : limit != nil && remaining != nil

        return Probe(
            remaining: remaining ?? 0,
            limit: limit ?? 0,
            resetTime: resetTime,
            keyValid: keyValid,
            requestLimitsReliable: requestLimitsReliable,
            statusCode: http.statusCode)
    }

    // MARK: - 映射到 CodexUsageSnapshot

    /// 把探针快照映射成会话/周用量。Doubao 只有「请求额度」一个窗口 → 放主窗（会话位），weekly 恒为 nil。
    /// 额度可信时按 used/limit*100 计已用百分比；否则记 0%。无重置周期时给 now+30 天兜底（与 CursorUsage 同惯例）。
    private static func snapshot(from probe: Probe) -> CodexUsageSnapshot {
        let usedPercent: Int
        if probe.limit > 0, probe.requestLimitsReliable {
            let used = max(0, probe.limit - probe.remaining)
            usedPercent = max(0, min(100, Int((Double(used) / Double(probe.limit) * 100).rounded())))
        } else {
            usedPercent = 0
        }
        let windowSeconds = 30 * 24 * 3600
        let session = CodexUsageSnapshot.Window(
            usedPercent: usedPercent,
            resetAt: probe.resetTime ?? Date().addingTimeInterval(TimeInterval(windowSeconds)),
            windowSeconds: windowSeconds)
        return CodexUsageSnapshot(planType: nil, session: session, weekly: nil)
    }

    // MARK: - 头/错误解析

    private static func stringHeader(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        if let value = headers[name] as? String { return value }
        for (key, val) in headers {
            if let keyStr = key as? String,
               keyStr.caseInsensitiveCompare(name) == .orderedSame,
               let valStr = val as? String
            {
                return valStr
            }
        }
        return nil
    }

    private static func intHeader(_ headers: [AnyHashable: Any], _ name: String) -> Int? {
        if let value = headers[name] as? String, let int = Int(value) { return int }
        if let value = headers[name.lowercased()] as? String, let int = Int(value) { return int }
        for (key, val) in headers {
            if let keyStr = key as? String,
               keyStr.lowercased() == name.lowercased(),
               let valStr = val as? String,
               let int = Int(valStr)
            {
                return int
            }
        }
        return nil
    }

    private static func parseResetTime(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) { return date }
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]
        if let date = isoFallback.date(from: trimmed) { return date }

        var seconds: TimeInterval = 0
        let pattern = /(\d+)([dhms])/
        for match in trimmed.matches(of: pattern) {
            guard let num = Double(match.1) else { continue }
            switch match.2 {
            case "d": seconds += num * 86400
            case "h": seconds += num * 3600
            case "m": seconds += num * 60
            case "s": seconds += num
            default: break
            }
        }
        if seconds > 0 { return Date().addingTimeInterval(seconds) }
        if let secs = TimeInterval(trimmed) { return Date().addingTimeInterval(secs) }
        return nil
    }

    private static func apiErrorSummary(statusCode: Int, data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = root as? [String: Any]
        else {
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                return compactText(text)
            }
            return "Unexpected response body (\(data.count) bytes)."
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String
        {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return compactText(trimmed) }
        }
        if let message = json["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return compactText(trimmed) }
        }
        return "HTTP \(statusCode) (\(data.count) bytes)."
    }

    private static func compactText(_ text: String, maxLength: Int = 200) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxLength { return collapsed }
        let limitIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return "\(collapsed[..<limitIndex])..."
    }
}
