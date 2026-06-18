import Foundation

/// Crof（crof.ai 套餐）用量取数。摘自 CodexBar `Crof` provider，自足、不依赖 cookie：
/// 用 `CROF_API_KEY` 走 `Bearer` 调 `https://crof.ai/usage_api/`，
/// 解析「可用请求数 / 请求额度」与「积分余额」。账号级（与具体 CLI 无关）。
///
/// 环境变量：`CROF_API_KEY`（必需）、`CROFAI_API_KEY`（可选回退）。
///
/// 说明：Crof 接口返回 `credits`（积分余额，无上限）、`requests_plan`（请求额度）、
/// `usable_requests`（剩余可用请求数）。映射到富 `UsageSnapshot`：
///   - 请求：已用百分比 = 100 - floor(可用 / 额度 * 100)，窗口为 24 小时，
///     重置时刻取下一个 America/Chicago 的零点 → `primary`（主窗）。
///   - 积分余额：接口只给余额、无额度上限 → `providerCost`（used = credits，
///     limit = 0 表示无上限，period = 余额）。
public enum CrofUsageError: LocalizedError, Sendable {
    case missingToken
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 Crof 令牌，请设置环境变量 CROF_API_KEY")
        case let .server(code): L("Crof 接口错误（%ld）", code)
        case .invalidResponse: L("Crof 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum CrofUsageFetcher {
    private static let usageURL = URL(string: "https://crof.ai/usage_api/")!
    private static let requestWindowSeconds = 24 * 60 * 60
    private static let resetTimeZone = TimeZone(identifier: "America/Chicago") ?? TimeZone(secondsFromGMT: -5)!

    /// 是否配置了 Crof 令牌（用于在工具面板里把 Crof 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        // 与 CodexBar CrofSettingsReader 一致：CROF_API_KEY → CROFAI_API_KEY，去引号去空白。
        for key in ["CROF_API_KEY", "CROFAI_API_KEY"] {
            if let v = clean(env[key]) { return v }
        }
        return nil
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
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw CrofUsageError.missingToken }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw CrofUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as CrofUsageError {
            throw e
        } catch {
            throw CrofUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else { throw CrofUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    private struct UsageResponse: Decodable {
        let credits: Double
        let requestsPlan: Double
        let usableRequests: Double

        enum CodingKeys: String, CodingKey {
            case credits
            case requestsPlan = "requests_plan"
            case usableRequests = "usable_requests"
        }
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let decoded: UsageResponse
        do {
            decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw CrofUsageError.invalidResponse
        }

        let now = Date()

        // 请求窗（主窗）：已用 = 100 - floor(可用/额度*100)，缺额度则视为已用满；24 小时窗口。
        let requestsUsed: Double
        if decoded.requestsPlan > 0 {
            let usable = max(0, min(decoded.requestsPlan, decoded.usableRequests))
            let remaining = max(0, min(100, floor(usable / decoded.requestsPlan * 100)))
            requestsUsed = max(0, min(100, 100 - remaining))
        } else {
            requestsUsed = 100
        }
        let primary = RateWindow(
            title: L("请求"), // Requests
            usedPercent: requestsUsed,
            windowMinutes: requestWindowSeconds / 60,
            resetsAt: nextRequestReset(after: now) ?? now.addingTimeInterval(TimeInterval(requestWindowSeconds)),
            resetDescription: formatRequestsLeft(decoded.usableRequests))

        // 积分余额：接口只给余额、无上限 → 放 providerCost（limit=0 表示无上限，按余额展示）。
        let providerCost = ProviderCostSnapshot(
            used: max(0, decoded.credits),
            limit: 0,
            currencyCode: "USD",
            period: L("余额")) // Balance

        return UsageSnapshot(
            primary: primary,
            providerCost: providerCost,
            updatedAt: now)
    }

    /// 剩余可用请求数的文本描述（整数不带小数，否则保留两位）。
    private static func formatRequestsLeft(_ value: Double) -> String {
        let clamped = max(0, value)
        let formatted = clamped.rounded() == clamped
            ? String(format: "%.0f", clamped)
            : String(format: "%.2f", clamped)
        return L("剩余 %@ 次请求", formatted) // "<n> requests left"
    }

    /// 下一个 America/Chicago 零点（24 小时请求窗口的重置时刻）。
    private static func nextRequestReset(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resetTimeZone
        let startOfDay = calendar.startOfDay(for: date)
        return startOfDay <= date
            ? calendar.date(byAdding: .day, value: 1, to: startOfDay)
            : startOfDay
    }
}
