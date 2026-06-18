import Foundation

/// Amp（Sourcegraph Amp，ampcode.com）用量取数。摘自 CodexBar `Amp` provider 的 **API token** 路径，
/// 自足、不依赖 cookie：用 `AMP_API_KEY` 走 `Bearer` POST `https://ampcode.com/api/internal?userDisplayBalanceInfo`，
/// 拿到 `result.displayText`（一段 CLI 风格的纯文本），用正则解析「Amp Free 额度 / 剩余 / 每小时回补」以及
/// 「Individual credits / Workspace 余额」。账号级（与具体 CLI 无关）。
///
/// 环境变量：`AMP_API_KEY`（必需）。CodexBar 还支持从浏览器读 ampcode.com 的 `session` cookie 走网页路径，
/// 但本转写优先 token —— token 路径只需 Foundation，无需 SweetCookieKit / 浏览器授权。
///
/// 字段/端点完全照搬 CodexBar，本机无 token 无法实跑验证。
public enum AmpUsageError: LocalizedError, Sendable {
    case missingToken
    case invalidToken
    case server(Int)
    case invalidResponse
    case apiError(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 Amp 令牌，请设置环境变量 AMP_API_KEY")
        case .invalidToken: L("Amp 令牌无效或已过期")
        case let .server(code): L("Amp 接口错误（%ld）", code)
        case .invalidResponse: L("Amp 用量接口返回异常")
        case let .apiError(m): L("Amp API 错误：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum AmpUsageFetcher {
    // 照搬 CodexBar：POST 到 internal RPC，method=userDisplayBalanceInfo。
    static let usageURL = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!
    private static let apiTokenKey = "AMP_API_KEY"

    /// 是否配置了 Amp 令牌（用于把 Amp 视作「可用」；纯本地检查，不发网络）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        clean(env[apiTokenKey])
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        guard let apiToken = token(env: env) else { throw AmpUsageError.missingToken }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "method": "userDisplayBalanceInfo",
            "params": [:],
        ])
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw AmpUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as AmpUsageError {
            throw e
        } catch {
            throw AmpUsageError.network(error.localizedDescription)
        }

        switch http.statusCode {
        case 200...299:
            return try parse(data, now: Date())
        case 401, 403:
            throw AmpUsageError.invalidToken
        default:
            throw AmpUsageError.server(http.statusCode)
        }
    }

    // MARK: - 解析

    private struct UsageAPIResponse: Decodable {
        let ok: Bool
        let result: Result?
        let error: APIError?

        struct Result: Decodable {
            let displayText: String
        }

        struct APIError: Decodable {
            let code: String?
            let message: String?
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> CodexUsageSnapshot {
        let response: UsageAPIResponse
        do {
            response = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        } catch {
            throw AmpUsageError.invalidResponse
        }
        guard response.ok else {
            if response.error?.code == "auth-required" { throw AmpUsageError.invalidToken }
            throw AmpUsageError.apiError(response.error?.message ?? "unknown")
        }
        guard let displayText = response.result?.displayText, !displayText.isEmpty else {
            throw AmpUsageError.invalidResponse
        }
        return try parse(displayText: displayText, now: now)
    }

    /// Amp Free 一档的额度/剩余/回补（金额单位 $）。
    private struct FreeTierUsage {
        let quota: Double
        let used: Double
        let hourlyReplenishment: Double
        let windowHours: Double?
    }

    static func parse(displayText: String, now: Date = Date()) throws -> CodexUsageSnapshot {
        let text = stripANSICodes(displayText)

        // 形如：`Signed in as alice@example.com (Acme)`，仅用于校验是否登录。
        let identityPattern = #"(?im)^\s*Signed in as\s+([^\s(]+)(?:\s+\(([^\r\n)]+)\))?\s*$"#
        let identity = captures(in: text, pattern: identityPattern)
        if identity == nil, looksSignedOut(text) {
            throw AmpUsageError.invalidToken
        }

        let amountPattern = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
        // 形如：`Amp Free: $4.20 / $10.00 remaining (replenishes +$0.50 / hour)`
        let freePattern = #"(?im)^\s*Amp Free:\s*\$?"# + amountPattern +
            #"\s*/\s*\$?"# + amountPattern +
            #"\s+remaining(?:\s*\(replenishes\s*\+\$?"# + amountPattern + #"\s*/\s*hour\))?"#

        let freeUsage: FreeTierUsage? = {
            guard let free = captures(in: text, pattern: freePattern),
                  let remaining = number(from: free[0]),
                  let quota = number(from: free[1])
            else { return nil }
            let hourlyReplenishment = number(from: free[2]) ?? 0
            let windowHours = hourlyReplenishment > 0
                ? max(1, (quota / hourlyReplenishment).rounded())
                : nil
            return FreeTierUsage(
                quota: quota,
                used: max(0, quota - remaining),
                hourlyReplenishment: hourlyReplenishment,
                windowHours: windowHours)
        }()

        // `Individual credits: $123.45 remaining`
        let creditsPattern = #"(?im)^\s*Individual credits:\s*\$?"# + amountPattern + #"\s+remaining"#
        let individualCredits = captures(in: text, pattern: creditsPattern)?.first.flatMap(number(from:))

        // `Workspace Acme: $67.89 remaining`（可多条）
        let workspacePattern = #"(?im)^\s*Workspace\s+(.+?):\s*\$?"# + amountPattern + #"\s+remaining"#
        let workspaceRemaining: [Double] = allCaptures(in: text, pattern: workspacePattern).compactMap { caps in
            guard caps.count == 2, nonEmpty(caps[0]) != nil else { return nil }
            return number(from: caps[1])
        }

        guard freeUsage != nil || individualCredits != nil || !workspaceRemaining.isEmpty else {
            throw AmpUsageError.invalidResponse
        }

        // 计划名：照搬 CodexBar 的 sessionLabel/weeklyLabel 含义 —— 主窗是 Amp Free。
        let planType = identity?.first.flatMap(nonEmpty)

        // session 窗 = Amp Free 一档。映射同 CodexBar `toUsageSnapshot`：
        //   usedPercent = used/quota*100；windowSeconds = windowHours*3600；
        //   resetAt = now + used/hourlyReplenishment*3600（回补到满所需时间）。
        if let free = freeUsage {
            let quota = max(0, free.quota)
            let used = max(0, free.used)
            let percent = quota > 0 ? min(100, used / quota * 100) : 0
            let windowSeconds = (free.windowHours.map { $0 > 0 ? Int(($0 * 3600).rounded()) : 0 }) ?? 0
            let resetAt: Date = {
                guard quota > 0, free.hourlyReplenishment > 0 else {
                    return now.addingTimeInterval(TimeInterval(windowSeconds > 0 ? windowSeconds : 86400))
                }
                return now.addingTimeInterval(max(0, used / free.hourlyReplenishment * 3600))
            }()
            let window = CodexUsageSnapshot.Window(
                usedPercent: max(0, min(100, Int(percent.rounded()))),
                resetAt: resetAt,
                windowSeconds: windowSeconds)
            return CodexUsageSnapshot(planType: planType, session: window, weekly: nil)
        }

        // 无 Amp Free 一档（纯余额账户）：没有用量周期 → session 占位，reset = now + 30 天，weekly = nil。
        // 余额本身是「剩余额度」而非「已用百分比」，无总额无法换算用量，故标记 0%（仅表示「已配置/可用」）。
        let window = CodexUsageSnapshot.Window(
            usedPercent: 0,
            resetAt: now.addingTimeInterval(30 * 24 * 3600),
            windowSeconds: 30 * 24 * 3600)
        return CodexUsageSnapshot(planType: planType, session: window, weekly: nil)
    }

    // MARK: - 文本工具（照搬 CodexBar AmpUsageParser）

    private static func stripANSICodes(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*[A-Za-z]") else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }

    private static func captures(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return captures(in: text, match: match)
    }

    private static func allCaptures(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).map { captures(in: text, match: $0) }
    }

    private static func captures(in text: String, match: NSTextCheckingResult) -> [String] {
        (1..<match.numberOfRanges).map { index in
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let range = Range(captureRange, in: text)
            else { return "" }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func number(from text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("sign in") || lower.contains("log in") || lower.contains("login") { return true }
        if lower.contains("/login") || lower.contains("ampcode.com/login") { return true }
        return false
    }
}
