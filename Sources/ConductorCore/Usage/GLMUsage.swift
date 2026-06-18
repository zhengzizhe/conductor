import Foundation

/// GLM / Z.ai（智谱 GLM 编码套餐）用量取数。摘自 CodexBar `Zai` provider，自足、不依赖 cookie：
/// 用 `Z_AI_API_KEY` 走 `Bearer` 调 `https://api.z.ai/api/monitor/usage/quota/limit`，
/// 解析 TOKENS_LIMIT / TIME_LIMIT 限额。账号级（与具体 CLI 无关）。
///
/// 环境变量：`Z_AI_API_KEY`（必需）、`Z_AI_API_HOST` / `Z_AI_QUOTA_URL`（可选覆盖，CN 用户可指向 open.bigmodel.cn）。
public enum GLMUsageError: LocalizedError, Sendable {
    case missingToken
    case server(Int)
    case invalidResponse
    case apiError(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 GLM(Z.ai) 令牌，请设置环境变量 Z_AI_API_KEY")
        case let .server(code): L("Z.ai 接口错误（%ld）", code)
        case .invalidResponse: L("Z.ai 用量接口返回异常")
        case let .apiError(m): L("Z.ai API 错误：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum GLMUsageFetcher {
    private static let quotaPath = "api/monitor/usage/quota/limit"
    private static let defaultHost = "https://api.z.ai"

    /// 是否配置了 GLM 令牌（用于在工具面板里把 GLM 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        for key in ["Z_AI_API_KEY", "ZAI_API_KEY", "GLM_API_KEY"] {
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

    static func quotaURL(env: [String: String]) -> URL {
        if let raw = clean(env["Z_AI_QUOTA_URL"]) {
            if let u = URL(string: raw), u.scheme != nil { return u }
            if let u = URL(string: "https://\(raw)") { return u }
        }
        let host = clean(env["Z_AI_API_HOST"]).map { $0.contains("://") ? $0 : "https://\($0)" } ?? defaultHost
        return URL(string: host)!.appendingPathComponent(quotaPath)
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw GLMUsageError.missingToken }

        var request = URLRequest(url: quotaURL(env: env))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw GLMUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as GLMUsageError {
            throw e
        } catch {
            throw GLMUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else { throw GLMUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    private struct Response: Decodable {
        let code: Int
        let success: Bool
        let msg: String?
        let data: Payload?
    }

    private struct Payload: Decodable {
        let limits: [LimitRaw]?
        let planName: String?
        enum CodingKeys: String, CodingKey {
            case limits, planName, plan
            case planType = "plan_type"
            case packageName
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            limits = try c.decodeIfPresent([LimitRaw].self, forKey: .limits) ?? []
            let candidates = [
                try? c.decodeIfPresent(String.self, forKey: .planName),
                try? c.decodeIfPresent(String.self, forKey: .plan),
                try? c.decodeIfPresent(String.self, forKey: .planType),
                try? c.decodeIfPresent(String.self, forKey: .packageName),
            ].compactMap { $0 }.compactMap { $0 }
            planName = candidates.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    private struct LimitRaw: Decodable {
        let type: String
        let unit: Int
        let number: Int
        let usage: Int?
        let currentValue: Int?
        let remaining: Int?
        let percentage: Int
        let nextResetTime: Int?
    }

    /// 一条限额的「已用百分比」「窗口秒数」「重置时刻」。
    private struct Limit {
        let isToken: Bool
        let usedPercent: Int
        let windowSeconds: Int?
        let resetAt: Date?
    }

    private static func makeLimit(_ raw: LimitRaw) -> Limit? {
        let isToken = raw.type == "TOKENS_LIMIT"
        let isTime = raw.type == "TIME_LIMIT"
        guard isToken || isTime else { return nil }

        // 优先用 usage/remaining/currentValue 精算，缺字段则回退 percentage（避免误判 100%）。
        var used: Double?
        if let limit = raw.usage, limit > 0 {
            var usedRaw: Int?
            if let remaining = raw.remaining {
                let fromRemaining = limit - remaining
                usedRaw = raw.currentValue.map { max(fromRemaining, $0) } ?? fromRemaining
            } else if let cv = raw.currentValue {
                usedRaw = cv
            }
            if let usedRaw {
                let u = max(0, min(limit, usedRaw))
                used = Double(u) / Double(limit) * 100
            }
        }
        let pct = used ?? Double(raw.percentage)
        let clamped = max(0, min(100, Int(pct.rounded())))

        let windowSeconds: Int? = raw.number > 0 ? {
            switch raw.unit {
            case 5: return raw.number * 60          // minutes
            case 3: return raw.number * 3600        // hours
            case 1: return raw.number * 86400       // days
            case 6: return raw.number * 7 * 86400   // weeks
            default: return nil
            }
        }() : nil
        let reset = raw.nextResetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        return Limit(isToken: isToken, usedPercent: clamped, windowSeconds: windowSeconds, resetAt: reset)
    }

    static func parse(_ data: Data) throws -> CodexUsageSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.success, response.code == 200 else {
            throw GLMUsageError.apiError(response.msg ?? "unknown")
        }
        guard let payload = response.data else { throw GLMUsageError.invalidResponse }

        let limits = (payload.limits ?? []).compactMap(makeLimit)
        let tokenLimits = limits.filter(\.isToken).sorted { ($0.windowSeconds ?? .max) < ($1.windowSeconds ?? .max) }
        let timeLimit = limits.first { !$0.isToken }

        // session = 最短 TOKENS_LIMIT（如 5 小时）；weekly = 最长 TOKENS_LIMIT 或 TIME_LIMIT（月）。
        let sessionLimit = tokenLimits.first
        let weeklyLimit = (tokenLimits.count >= 2 ? tokenLimits.last : nil) ?? timeLimit

        func window(_ l: Limit?) -> CodexUsageSnapshot.Window? {
            guard let l else { return nil }
            let secs = l.windowSeconds ?? 0
            return CodexUsageSnapshot.Window(
                usedPercent: l.usedPercent,
                resetAt: l.resetAt ?? Date().addingTimeInterval(TimeInterval(secs > 0 ? secs : 86400)),
                windowSeconds: secs)
        }

        let session = window(sessionLimit)
        let weekly = window(weeklyLimit)
        guard session != nil || weekly != nil else { throw GLMUsageError.invalidResponse }
        return CodexUsageSnapshot(planType: payload.planName, session: session, weekly: weekly)
    }
}
