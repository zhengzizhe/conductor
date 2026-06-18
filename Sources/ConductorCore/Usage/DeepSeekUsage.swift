import Foundation

/// DeepSeek（平台余额）用量取数。摘自 CodexBar `DeepSeek` provider，自足、不依赖 cookie：
/// 用 `DEEPSEEK_API_KEY` 走 `Bearer` 调 `https://api.deepseek.com/user/balance`，
/// 解析账户余额（credits/$）。账号级（与具体 CLI 无关）。
///
/// 环境变量：`DEEPSEEK_API_KEY`（必需）、`DEEPSEEK_KEY`（可选回退）。
///
/// 说明：DeepSeek 余额接口只返回当前余额（无原始额度、无周期窗口），不像 token/time 限额那样
/// 有「已用/总额」。这里忠实照搬 CodexBar 的判定：余额可用且为正 → 已用 0%；余额为 0 或
/// `is_available=false` → 已用 100%。因无周期，结果放 `session`，重置时间取 now+30 天，`weekly=nil`。
public enum DeepSeekUsageError: LocalizedError, Sendable {
    case missingToken
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 DeepSeek 令牌，请设置环境变量 DEEPSEEK_API_KEY")
        case let .server(code): L("DeepSeek 接口错误（%ld）", code)
        case .invalidResponse: L("DeepSeek 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum DeepSeekUsageFetcher {
    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    /// 是否配置了 DeepSeek 令牌（用于在工具面板里把 DeepSeek 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        // 与 CodexBar DeepSeekSettingsReader 一致：DEEPSEEK_API_KEY → DEEPSEEK_KEY，去引号去空白。
        for key in ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"] {
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
        guard let apiKey = token(env: env) else { throw DeepSeekUsageError.missingToken }

        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw DeepSeekUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as DeepSeekUsageError {
            throw e
        } catch {
            throw DeepSeekUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else { throw DeepSeekUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    private struct BalanceResponse: Decodable {
        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    private struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    private struct ParsedBalance {
        let currency: String
        let totalBalance: Double
        let grantedBalance: Double
        let toppedUpBalance: Double
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let decoded: BalanceResponse
        do {
            decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw DeepSeekUsageError.invalidResponse
        }

        let balances: [ParsedBalance] = decoded.balanceInfos.compactMap { info in
            guard let total = Double(info.totalBalance),
                  let granted = Double(info.grantedBalance),
                  let toppedUp = Double(info.toppedUpBalance)
            else { return nil }
            return ParsedBalance(
                currency: info.currency,
                totalBalance: total,
                grantedBalance: granted,
                toppedUpBalance: toppedUp)
        }

        // 与 CodexBar 一致：优先选有正余额的 USD，再退而求其次。空账户视为不可用。
        let selected = balances.first(where: { $0.currency == "USD" && $0.totalBalance > 0 })
            ?? balances.first(where: { $0.totalBalance > 0 })
            ?? balances.first(where: { $0.currency == "USD" })
            ?? balances.first

        // 余额可用且为正 → 0%；余额为 0 或 is_available=false → 100%。
        let currency = selected?.currency ?? "USD"
        let totalBalance = selected?.totalBalance ?? 0
        let usedPercent: Double = (totalBalance > 0 && decoded.isAvailable) ? 0 : 100

        // DeepSeek 是纯余额模型（无消费上限）：把真实余额放进 providerCost（limit<=0 表示无上限），
        // 币种照搬源里的 currency（USD/CNY 均原样）。
        let providerCost = ProviderCostSnapshot(
            used: totalBalance,
            limit: 0,
            currencyCode: currency,
            period: "Balance")

        // 保留一个余额占比窗作为 primary（标签 "Balance"），承载可用/耗尽的 0%/100% 语义。
        let primary = RateWindow(
            title: L("余额"),
            usedPercent: usedPercent)

        return UsageSnapshot(
            primary: primary,
            providerCost: providerCost)
    }
}
