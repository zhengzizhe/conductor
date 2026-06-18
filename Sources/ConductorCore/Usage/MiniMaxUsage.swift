import Foundation

/// MiniMax（编码套餐）用量取数。摘自 CodexBar `MiniMax` 的 apiToken 路径，自足、不依赖 cookie：
/// 用 `MINIMAX_API_KEY` / `MINIMAX_CODING_API_KEY` 走 `Bearer` 调 remains 接口，
/// 解析 `model_remains` 的「当前周期」与「周」剩余百分比。
///
/// 注意：照搬自 CodexBar 源码，但本环境无 key 无法实跑验证，字段映射以其 Decodable 定义为准。
public enum MiniMaxUsageError: LocalizedError, Sendable {
    case missingToken
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 MiniMax 令牌，请设置 MINIMAX_API_KEY 或 MINIMAX_CODING_API_KEY")
        case .unauthorized: L("MiniMax 令牌无效或已过期")
        case let .server(c): L("MiniMax 接口错误（%ld）", c)
        case .invalidResponse: L("MiniMax 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum MiniMaxUsageFetcher {
    /// 候选 remains 端点：全球(.io) 先 token_plan 后 coding_plan，失败再试中国(.com)。
    private static let hosts = ["https://api.minimax.io", "https://api.minimaxi.com"]
    private static let paths = ["v1/token_plan/remains", "v1/api/openplatform/coding_plan/remains"]

    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        for key in ["MINIMAX_CODING_API_KEY", "MINIMAX_API_KEY"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return nil
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw MiniMaxUsageError.missingToken }

        var lastError: Error = MiniMaxUsageError.invalidResponse
        for host in hosts {
            for path in paths {
                guard let url = URL(string: "\(host)/\(path)") else { continue }
                do {
                    return try await fetchOnce(url: url, apiKey: apiKey, session: session)
                } catch let e as MiniMaxUsageError {
                    lastError = e
                    if case .unauthorized = e { continue } // 换下一个端点/区域
                    continue
                } catch {
                    lastError = MiniMaxUsageError.network(error.localizedDescription)
                    continue
                }
            }
        }
        throw lastError
    }

    private static func fetchOnce(url: URL, apiKey: String, session: URLSession) async throws -> UsageSnapshot {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Conductor", forHTTPHeaderField: "MM-API-Source")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MiniMaxUsageError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw MiniMaxUsageError.unauthorized }
        guard http.statusCode == 200 else { throw MiniMaxUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    private struct Payload: Decodable {
        let baseResp: BaseResp?
        let data: PlanData?
        enum CodingKeys: String, CodingKey { case baseResp = "base_resp", data }
    }

    private struct PlanData: Decodable {
        let baseResp: BaseResp?
        let planName: String?
        let subscribeTitle: String?
        let modelRemains: [ModelRemains]?
        /// 积分/点数余额，对应 CodexBar 的 pointsBalance（多键兜底）。
        let pointsBalance: Double?
        enum CodingKeys: String, CodingKey {
            case baseResp = "base_resp"
            case planName = "plan_name"
            case subscribeTitle = "current_subscribe_title"
            case modelRemains = "model_remains"
            case pointsBalance = "points_balance"
            case pointBalance = "point_balance"
            case creditsBalance = "credits_balance"
            case creditBalance = "credit_balance"
            case balance
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.baseResp = try c.decodeIfPresent(BaseResp.self, forKey: .baseResp)
            self.planName = try c.decodeIfPresent(String.self, forKey: .planName)
            self.subscribeTitle = try c.decodeIfPresent(String.self, forKey: .subscribeTitle)
            self.modelRemains = try c.decodeIfPresent([ModelRemains].self, forKey: .modelRemains)
            self.pointsBalance = PlanData.decodeDouble(c, forKeys: [
                .pointsBalance, .pointBalance, .creditsBalance, .creditBalance, .balance,
            ])
        }

        /// 数值可能以 Double / Int / Int64 / String 形式出现，逐键、逐类型兜底。
        private static func decodeDouble(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKeys keys: [CodingKeys]) -> Double?
        {
            for key in keys {
                if let v = try? container.decodeIfPresent(Double.self, forKey: key) { return v }
                if let v = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(v) }
                if let v = try? container.decodeIfPresent(Int64.self, forKey: key) { return Double(v) }
                if let v = try? container.decodeIfPresent(String.self, forKey: key),
                   let d = Double(v.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
            }
            return nil
        }
    }

    private struct BaseResp: Decodable {
        let statusCode: Int?
        let statusMsg: String?
        enum CodingKeys: String, CodingKey { case statusCode = "status_code", statusMsg = "status_msg" }
    }

    private struct ModelRemains: Decodable {
        let intervalRemainingPercent: Double?
        let endTime: Int?
        let remainsTime: Int?
        let weeklyRemainingPercent: Double?
        let weeklyEndTime: Int?
        let weeklyRemainsTime: Int?
        enum CodingKeys: String, CodingKey {
            case intervalRemainingPercent = "current_interval_remaining_percent"
            case endTime = "end_time"
            case remainsTime = "remains_time"
            case weeklyRemainingPercent = "current_weekly_remaining_percent"
            case weeklyEndTime = "weekly_end_time"
            case weeklyRemainsTime = "weekly_remains_time"
        }
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let base = payload.data?.baseResp ?? payload.baseResp
        if let status = base?.statusCode, status != 0 {
            let msg = (base?.statusMsg ?? "").lowercased()
            if status == 1004 || msg.contains("login") || msg.contains("log in") || msg.contains("cookie") {
                throw MiniMaxUsageError.unauthorized
            }
            throw MiniMaxUsageError.server(status)
        }
        guard let models = payload.data?.modelRemains, !models.isEmpty else {
            throw MiniMaxUsageError.invalidResponse
        }

        // 取「当前周期剩余最低」的车道作为会话窗，并用它的周窗。
        let lane = models.min { ($0.intervalRemainingPercent ?? 100) < ($1.intervalRemainingPercent ?? 100) }
            ?? models[0]

        func used(_ remainingPercent: Double?) -> Double? {
            guard let r = remainingPercent else { return nil }
            return max(0, min(100, 100 - r))
        }
        func resetAt(end: Int?, remains: Int?, fallbackSeconds: Int) -> Date {
            if let end, end > 0 { return dateFromUnix(end) }
            if let remains, remains > 0 { return Date().addingTimeInterval(TimeInterval(remains)) }
            return Date().addingTimeInterval(TimeInterval(fallbackSeconds))
        }

        // session → primary、weekly → secondary。
        var primary: RateWindow?
        if let u = used(lane.intervalRemainingPercent) {
            primary = RateWindow(
                title: L("会话"),
                usedPercent: u,
                windowMinutes: 5 * 60,
                resetsAt: resetAt(end: lane.endTime, remains: lane.remainsTime, fallbackSeconds: 5 * 3600))
        }
        var secondary: RateWindow?
        if let u = used(lane.weeklyRemainingPercent) {
            secondary = RateWindow(
                title: L("本周"),
                usedPercent: u,
                windowMinutes: 7 * 24 * 60,
                resetsAt: resetAt(end: lane.weeklyEndTime, remains: lane.weeklyRemainsTime, fallbackSeconds: 7 * 24 * 3600))
        }
        guard primary != nil || secondary != nil else { throw MiniMaxUsageError.invalidResponse }

        // MiniMax 是积分/points 余额，无上限 → providerCost。对应 CodexBar pointsBalanceSnapshot()。
        var providerCost: ProviderCostSnapshot?
        if let balance = payload.data?.pointsBalance, balance >= 0 {
            providerCost = ProviderCostSnapshot(
                used: balance,
                limit: 0,
                currencyCode: "Points",
                period: "MiniMax points balance")
        }

        let plan = payload.data?.subscribeTitle ?? payload.data?.planName
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            providerCost: providerCost,
            planName: plan)
    }

    /// 时间戳可能是秒或毫秒。
    private static func dateFromUnix(_ value: Int) -> Date {
        let secs = value > 1_000_000_000_000 ? Double(value) / 1000 : Double(value)
        return Date(timeIntervalSince1970: secs)
    }
}
