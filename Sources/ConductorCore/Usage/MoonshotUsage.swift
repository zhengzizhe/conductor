import Foundation

/// Moonshot / Kimi API 账号余额取数。摘自 CodexBar `Moonshot` provider，自足、不依赖 cookie：
/// 用 `MOONSHOT_API_KEY` 走 `Bearer` 调 `https://api.moonshot.ai/v1/users/me/balance`
/// （国内区 `MOONSHOT_REGION=china` → `https://api.moonshot.cn`），
/// 解析 `available_balance` / `voucher_balance` / `cash_balance`。账号级（与具体 CLI 无关）。
///
/// 环境变量：`MOONSHOT_API_KEY` 或 `MOONSHOT_KEY`（必需）、`MOONSHOT_REGION`（可选：`international` / `china`，默认国际）。
///
/// 注意：Moonshot 余额接口只返回「剩余余额」，没有「额度/已用」窗口概念（CodexBar 也不产任何
/// session/weekly 速率窗，只在卡片里展示可用余额与可能的欠款）。因此 Moonshot 本质是「美元余额」型
/// provider：把 `available_balance` 折算成结构化的 `ProviderCostSnapshot`（used=余额、limit=0 表示
/// 无消费上限、currencyCode "USD"），并保留一个 "余额" 占比窗（primary）承载耗尽语义——余额耗尽
/// （available ≤ 0）记 100%，否则 0%。若 `cash_balance < 0`（账户透支）则在 period 文案里附上欠款金额
/// （"余额 · 欠款 $X"）。`voucher_balance` 仍解析但不展示（与 CodexBar 卡片语义一致）。
/// primary 窗无固定周期，reset 取 now + 30 天。
public enum MoonshotUsageError: LocalizedError, Sendable {
    case missingToken
    case server(Int)
    case invalidResponse
    case apiError(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 Moonshot 令牌，请设置环境变量 MOONSHOT_API_KEY")
        case let .server(code): L("Moonshot 接口错误（%ld）", code)
        case .invalidResponse: L("Moonshot 用量接口返回异常")
        case let .apiError(m): L("Moonshot API 错误：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum MoonshotUsageFetcher {
    private static let balancePath = "v1/users/me/balance"
    private static let internationalHost = "https://api.moonshot.ai"
    private static let chinaHost = "https://api.moonshot.cn"

    private static let apiKeyEnvironmentKeys = ["MOONSHOT_API_KEY", "MOONSHOT_KEY"]
    private static let regionEnvironmentKey = "MOONSHOT_REGION"

    /// 是否配置了 Moonshot 令牌（用于在工具面板里把 Moonshot 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        for key in apiKeyEnvironmentKeys {
            if let v = clean(env[key]) { return v }
        }
        return nil
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 解析区域：`MOONSHOT_REGION=china` → 国内站，其余默认国际站。
    static func balanceURL(env: [String: String]) -> URL {
        let region = clean(env[regionEnvironmentKey])?.lowercased()
        let host = region == "china" ? chinaHost : internationalHost
        return URL(string: host)!.appendingPathComponent(balancePath)
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw MoonshotUsageError.missingToken }

        var request = URLRequest(url: balanceURL(env: env))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw MoonshotUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as MoonshotUsageError {
            throw e
        } catch {
            throw MoonshotUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else { throw MoonshotUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    private struct Response: Decodable {
        let code: Int
        let data: Payload
        let scode: String
        let status: Bool
    }

    private struct Payload: Decodable {
        let availableBalance: Double
        let voucherBalance: Double
        let cashBalance: Double

        enum CodingKeys: String, CodingKey {
            case availableBalance = "available_balance"
            case voucherBalance = "voucher_balance"
            case cashBalance = "cash_balance"
        }
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MoonshotUsageError.invalidResponse
        }
        guard response.code == 0, response.status else {
            throw MoonshotUsageError.apiError("code \(response.code), scode \(response.scode)")
        }

        // Moonshot 是「美元余额」型 provider：available_balance 是当前可用余额。
        // voucher_balance（代金券）与 cash_balance（现金，可负）仅作辅助；CodexBar 卡片只展示
        // available + 可能的欠款，voucher 不展示，这里照搬该语义。
        let available = response.data.availableBalance
        let cash = response.data.cashBalance

        // 余额耗尽（available ≤ 0）→ 100%，否则 0%；承载「可用/耗尽」语义的占比窗。
        let usedPercent: Double = available <= 0 ? 100 : 0
        let primary = RateWindow(
            title: L("余额"),
            usedPercent: usedPercent,
            resetsAt: Date().addingTimeInterval(30 * 86400))

        // 真实美元余额放进结构化 providerCost（limit=0 表示纯余额、无消费上限）。
        // cash_balance < 0 表示账户透支，把欠款金额并入 period 文案（与 CodexBar 「in deficit」一致）。
        let period: String
        if cash < 0 {
            period = L("余额 · 欠款 $%@", String(format: "%.2f", abs(cash)))
        } else {
            period = L("余额")
        }
        let providerCost = ProviderCostSnapshot(
            used: available,
            limit: 0,
            currencyCode: "USD",
            period: period)

        return UsageSnapshot(
            primary: primary,
            providerCost: providerCost)
    }
}
