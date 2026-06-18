import Foundation

/// Kimi K2（kimi-k2.ai 第三方站点，独立于 Moonshot Kimi）积分用量取数。摘自 CodexBar `KimiK2` provider，
/// 自足、不依赖 cookie：用 `KIMI_K2_API_KEY` 走 `Bearer` 调 `https://kimi-k2.ai/api/user/credits`，
/// 解析「已消耗积分 / 剩余积分」。账号级（与具体 CLI 无关）。
///
/// 环境变量（按序回退，对应 CodexBar KimiK2SettingsReader）：
/// `KIMI_K2_API_KEY` / `KIMI_API_KEY` / `KIMI_KEY`（任一即可）。
///
/// 注意：
/// - 此 provider 与 `KimiUsage.swift`（Moonshot 官方 Kimi 编码套餐，`KIMI_CODE_API_KEY`）完全不同，互不复用。
/// - 积分接口只返回「已消耗 / 剩余」，没有「速率窗口/重置周期」概念。因此 Kimi K2 本质是「额度/余额」型
///   provider，没有 session/weekly 滑动窗：消耗与剩余折算成 `ProviderCostSnapshot`（providerCost），
///   used = consumed，limit = consumed + remaining（总购买积分当作上限；二者皆为 0 时 limit ≤ 0 表示无上限），
///   货币用 "credits"、period 标 "积分余额"。primary/secondary/tertiary 全为 nil。
///   （CodexBar 原实现也不产任何 RateWindow，只把剩余积分塞进 identity 文案。）
/// - 响应 JSON 字段命名不固定，照搬 CodexBar 的多路径候选 + 多层 context（data/result/usage/credits）遍历策略。
/// - 照搬自 CodexBar 源码，本环境无 key 无法实跑验证，字段映射以其实现为准。
public enum KimiK2UsageError: LocalizedError, Sendable {
    case missingToken
    case server(Int)
    case invalidResponse
    case apiError(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 Kimi K2 令牌，请设置环境变量 KIMI_K2_API_KEY")
        case let .server(code): L("Kimi K2 接口错误（%ld）", code)
        case .invalidResponse: L("Kimi K2 用量接口返回异常")
        case let .apiError(m): L("Kimi K2 API 错误：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum KimiK2UsageFetcher {
    private static let creditsURL = URL(string: "https://kimi-k2.ai/api/user/credits")!

    private static let apiKeyEnvironmentKeys = ["KIMI_K2_API_KEY", "KIMI_API_KEY", "KIMI_KEY"]

    // 对应 CodexBar KimiK2UsageFetcher 的字段候选路径。
    private static let consumedPaths: [[String]] = [
        ["total_credits_consumed"], ["totalCreditsConsumed"],
        ["total_credits_used"], ["totalCreditsUsed"],
        ["credits_consumed"], ["creditsConsumed"],
        ["consumedCredits"], ["usedCredits"],
        ["total"], ["usage", "total"], ["usage", "consumed"],
    ]

    private static let remainingPaths: [[String]] = [
        ["credits_remaining"], ["creditsRemaining"],
        ["remaining_credits"], ["remainingCredits"],
        ["available_credits"], ["availableCredits"],
        ["credits_left"], ["creditsLeft"],
        ["usage", "credits_remaining"], ["usage", "remaining"],
    ]

    /// 是否配置了 Kimi K2 令牌（用于在账号用量区把 Kimi K2 视作「可用」）。
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

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw KimiK2UsageError.missingToken }

        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw KimiK2UsageError.invalidResponse }
            data = d
            http = h
        } catch let e as KimiK2UsageError {
            throw e
        } catch {
            throw KimiK2UsageError.network(error.localizedDescription)
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw KimiK2UsageError.apiError(body)
        }
        return try parse(data)
    }

    // MARK: - 解析

    static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dictionary = json as? [String: Any]
        else {
            throw KimiK2UsageError.invalidResponse
        }

        let contexts = contexts(from: dictionary)
        let consumed = max(0, doubleValue(for: consumedPaths, in: contexts) ?? 0)
        let remaining = max(0, doubleValue(for: remainingPaths, in: contexts) ?? 0)

        // 积分型 provider：无滑动窗口，把「已消耗 / 剩余」折算成额度快照。
        // used = 已消耗；limit = 已消耗 + 剩余（总购买积分当作上限）；二者皆 0 时 limit ≤ 0 表示无明确上限。
        let limit = consumed + remaining
        let providerCost = ProviderCostSnapshot(
            used: consumed,
            limit: limit,
            currencyCode: "credits",
            period: L("积分余额"))

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: providerCost)
    }

    /// 把根字典展开成多层 context（含 data/result/usage/credits 嵌套），与 CodexBar 一致。
    private static func contexts(from dictionary: [String: Any]) -> [[String: Any]] {
        var contexts: [[String: Any]] = [dictionary]
        if let data = dictionary["data"] as? [String: Any] {
            contexts.append(data)
            if let dataUsage = data["usage"] as? [String: Any] { contexts.append(dataUsage) }
            if let dataCredits = data["credits"] as? [String: Any] { contexts.append(dataCredits) }
        }
        if let result = dictionary["result"] as? [String: Any] {
            contexts.append(result)
            if let resultUsage = result["usage"] as? [String: Any] { contexts.append(resultUsage) }
            if let resultCredits = result["credits"] as? [String: Any] { contexts.append(resultCredits) }
        }
        if let usage = dictionary["usage"] as? [String: Any] { contexts.append(usage) }
        if let credits = dictionary["credits"] as? [String: Any] { contexts.append(credits) }
        return contexts
    }

    private static func doubleValue(for paths: [[String]], in contexts: [[String: Any]]) -> Double? {
        for path in paths {
            if let raw = value(for: path, in: contexts), let v = double(from: raw) { return v }
        }
        return nil
    }

    private static func value(for path: [String], in contexts: [[String: Any]]) -> Any? {
        for context in contexts {
            var cursor: Any? = context
            for key in path {
                if let dict = cursor as? [String: Any] {
                    cursor = dict[key]
                } else {
                    cursor = nil
                }
            }
            if cursor != nil { return cursor }
        }
        return nil
    }

    private static func double(from raw: Any) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? String { return Double(v) }
        return nil
    }
}
