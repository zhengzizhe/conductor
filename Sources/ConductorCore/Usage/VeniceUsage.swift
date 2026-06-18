import Foundation

/// Venice（Venice.ai）用量取数。忠实摘自 CodexBar `Venice` provider，自足、不依赖 cookie：
/// 用 `VENICE_API_KEY` 走 `Bearer` 调 `https://api.venice.ai/api/v1/billing/balance`，
/// 解析 DIEM / USD 余额与 epoch 额度。账号级（与具体 CLI 无关）。
///
/// 余额接口没有「窗口/重置」概念，因此把真实余额承载进富模型的 `providerCost`：
/// - USD 活跃货币：`ProviderCostSnapshot(used: usdBalance, limit: 0, currencyCode: "USD", period: "Balance")`；
/// - DIEM 活跃货币：同形但 `currencyCode: "DIEM"`（diem 是积分，用 DIEM 标）；
///   若带 epoch 额度则 `limit = allocation`、`used = allocation - 余额`，并保留一个百分比 `primary` 窗（"DIEM 配额"）。
/// 纯余额（无额度）时 `primary` 置 nil，只剩 providerCost。
///
/// 环境变量：`VENICE_API_KEY` 或 `VENICE_KEY`（必需）。
public enum VeniceUsageError: LocalizedError, Sendable {
    case missingToken
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 Venice 令牌，请设置环境变量 VENICE_API_KEY")
        case let .server(code): L("Venice 接口错误（%ld）", code)
        case .invalidResponse: L("Venice 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum VeniceUsageFetcher {
    private static let balanceURL = URL(string: "https://api.venice.ai/api/v1/billing/balance")!

    /// 是否配置了 Venice 令牌（用于在工具面板里把 Venice 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        for key in ["VENICE_API_KEY", "VENICE_KEY"] {
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

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw VeniceUsageError.missingToken }

        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw VeniceUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as VeniceUsageError {
            throw e
        } catch {
            throw VeniceUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else { throw VeniceUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    private struct BalanceResponse: Decodable {
        let canConsume: Bool
        let consumptionCurrency: String?
        let balances: Balances
        let diemEpochAllocation: Double?

        enum CodingKeys: String, CodingKey {
            case canConsume
            case consumptionCurrency
            case balances
            case diemEpochAllocation
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            canConsume = try c.decode(Bool.self, forKey: .canConsume)
            consumptionCurrency = try c.decodeIfPresent(String.self, forKey: .consumptionCurrency)
            balances = try c.decode(Balances.self, forKey: .balances)
            diemEpochAllocation = try c.decodeFlexibleDoubleIfPresent(forKey: .diemEpochAllocation)
        }
    }

    private struct Balances: Decodable {
        let diem: Double?
        let usd: Double?

        enum CodingKeys: String, CodingKey {
            case diem
            case usd
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            diem = try c.decodeFlexibleDoubleIfPresent(forKey: .diem)
            usd = try c.decodeFlexibleDoubleIfPresent(forKey: .usd)
        }
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let decoded: BalanceResponse
        do {
            decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw VeniceUsageError.invalidResponse
        }
        return self.makeSnapshot(
            canConsume: decoded.canConsume,
            consumptionCurrency: decoded.consumptionCurrency,
            diemBalance: decoded.balances.diem,
            usdBalance: decoded.balances.usd,
            diemEpochAllocation: decoded.diemEpochAllocation)
    }

    /// 把 Venice 余额映射成富模型：真实余额进 `providerCost`，DIEM 带额度时另留一个百分比 `primary` 窗。
    /// 摘自 CodexBar `VeniceUsageSnapshot.toUsageSnapshot()` 的分支语义，但承载到余额/额度而非单一百分比窗。
    static func makeSnapshot(
        canConsume: Bool,
        consumptionCurrency: String?,
        diemBalance: Double?,
        usdBalance: Double?,
        diemEpochAllocation: Double?) -> UsageSnapshot
    {
        let activeCurrency = consumptionCurrency?.uppercased()

        if !canConsume {
            // 余额无法用于 API 调用：无可展示余额，主窗标记为已耗尽。
            return UsageSnapshot(primary: RateWindow(title: L("余额"), usedPercent: 100))
        }

        if activeCurrency == "USD", let usd = usdBalance, usd > 0 {
            return UsageSnapshot(providerCost: ProviderCostSnapshot(
                used: usd, limit: 0, currencyCode: "USD", period: L("余额")))
        }

        if activeCurrency != "USD", let diem = diemBalance, let allocation = diemEpochAllocation,
           allocation > 0
        {
            // DIEM 有 epoch 额度：保留 (额度-余额)/额度 的百分比窗，并把额度/已用塞进 providerCost。
            let usedAmount = clamp(allocation - diem, min: 0, max: allocation)
            let percent = clamp(usedAmount / allocation * 100, min: 0, max: 100)
            return UsageSnapshot(
                primary: RateWindow(title: L("DIEM 配额"), usedPercent: percent),
                providerCost: ProviderCostSnapshot(
                    used: usedAmount, limit: allocation, currencyCode: "DIEM", period: L("配额")))
        }

        if activeCurrency == "DIEM", let diem = diemBalance, diem > 0 {
            return UsageSnapshot(providerCost: ProviderCostSnapshot(
                used: diem, limit: 0, currencyCode: "DIEM", period: L("余额")))
        }

        if let diem = diemBalance, diem > 0 {
            // 纯 DIEM 余额（无额度）。
            return UsageSnapshot(providerCost: ProviderCostSnapshot(
                used: diem, limit: 0, currencyCode: "DIEM", period: L("余额")))
        }

        if let usd = usdBalance, usd > 0 {
            // 纯 USD 余额。
            return UsageSnapshot(providerCost: ProviderCostSnapshot(
                used: usd, limit: 0, currencyCode: "USD", period: L("余额")))
        }

        // 无任何余额：主窗标记为已耗尽。
        return UsageSnapshot(primary: RateWindow(title: L("余额"), usedPercent: 100))
    }
}

// MARK: - 辅助

private func clamp(_ value: Double, min: Double, max: Double) -> Double {
    Swift.min(Swift.max(value, min), max)
}

extension KeyedDecodingContainer {
    fileprivate func decodeFlexibleDoubleIfPresent(forKey key: K) throws -> Double? {
        if try self.decodeNil(forKey: key) {
            return nil
        }
        if let value = try? self.decode(Double.self, forKey: key) {
            return value
        }
        if let stringValue = try? self.decode(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let parsed = Double(trimmed) {
                return parsed
            }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a numeric string for \(key.stringValue), got '\(stringValue)'")
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected a number or numeric string for \(key.stringValue)")
    }
}
