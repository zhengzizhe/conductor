import Foundation

/// Kilo（Kilo Code）用量取数。忠实摘自 CodexBar `Kilo` provider，自足、不依赖 cookie。
///
/// 凭证为 Bearer token，优先级照搬 CodexBar `KiloBearerTokenResolver`：
/// 1) 环境变量 `KILO_API_KEY`；
/// 2) CLI 登录文件 `~/.local/share/kilo/auth.json` 里的 `kilo.access`（`HOME` 可覆盖）。
///
/// 走 tRPC batch 调 `https://app.kilo.ai/api/trpc/<procedures>?batch=1&input=...`，
/// 批量拉 `user.getCreditBlocks` / `kiloPass.getState` / `user.getAutoTopUpPaymentMethod`，
/// 解析「积分余额（credits）」与「Kilo Pass 订阅用量（$）」两套额度。
///
/// 映射到富 `UsageSnapshot`（见 UsageModels.swift）：
/// - credits（积分余额）= providerCost：used=creditsUsed、limit=creditsUsed+creditsRemaining（总额度）；
///   若只有 remaining → used=remaining、limit=0（无上限）、period「余额」；currencyCode "USD"。
/// - Kilo Pass（订阅用量 $）= primary：used/total*100；有 `passResetsAt` 则用之。
/// - 无 Pass → primary = nil。planName 透传到 `UsageSnapshot.planName`。
public enum KiloUsageError: LocalizedError, Sendable {
    case missingCredentials
    case unauthorized
    case endpointNotFound
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: L("未找到 Kilo 凭证，请设置环境变量 KILO_API_KEY 或运行 `kilo login`")
        case .unauthorized: L("Kilo 鉴权失败（401/403），请刷新 KILO_API_KEY 或重新运行 `kilo login`")
        case .endpointNotFound: L("Kilo 接口未找到（404）")
        case let .server(code): L("Kilo 接口错误（%ld）", code)
        case .invalidResponse: L("Kilo 用量接口返回异常")
        case let .network(msg): L("网络错误：%@", msg)
        }
    }
}

public enum KiloUsageFetcher {
    static let apiTokenKey = "KILO_API_KEY"
    private static let baseURL = URL(string: "https://app.kilo.ai/api/trpc")!

    /// tRPC 批量过程，顺序与解析逻辑强绑定（照搬 CodexBar）。
    private static let procedures = [
        "user.getCreditBlocks",
        "kiloPass.getState",
        "user.getAutoTopUpPaymentMethod",
    ]
    /// 可选过程：缺失/报错不致命（其余必需）。
    private static let optionalProcedures: Set<String> = [
        "user.getAutoTopUpPaymentMethod",
    ]
    private static let maxTopLevelEntries = procedures.count

    // MARK: - 凭证（优先 env token，再回退 CLI auth.json）

    /// 是否存在 Kilo 凭证（便宜的本地检查，不发网络、不弹钥匙串授权框）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        if let v = clean(env[apiTokenKey]) { return v }
        return cliToken(env: env)
    }

    /// 读 `~/.local/share/kilo/auth.json`（或 `$HOME` 覆盖）里的 `kilo.access`。
    static func cliToken(env: [String: String]) -> String? {
        let url = authFileURL(env: env)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseAuthToken(data: data)
    }

    static func authFileURL(env: [String: String]) -> URL {
        let home: URL = if let raw = clean(env["HOME"]) {
            URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
        }
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("kilo", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    static func parseAuthToken(data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(AuthFile.self, from: data) else { return nil }
        return clean(payload.kilo?.access)
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private struct AuthFile: Decodable {
        let kilo: KiloSection?
        struct KiloSection: Decodable { let access: String? }
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw KiloUsageError.missingCredentials }

        var request = URLRequest(url: try makeBatchURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw KiloUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as KiloUsageError {
            throw e
        } catch {
            throw KiloUsageError.network(error.localizedDescription)
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw KiloUsageError.unauthorized
        case 404:
            throw KiloUsageError.endpointNotFound
        case 500...599:
            throw KiloUsageError.server(http.statusCode)
        default:
            throw KiloUsageError.server(http.statusCode)
        }

        return try parse(data)
    }

    private static func makeBatchURL() throws -> URL {
        let endpoint = baseURL.appendingPathComponent(procedures.joined(separator: ","))
        let inputMap = Dictionary(uniqueKeysWithValues: procedures.indices.map {
            (String($0), ["json": NSNull()])
        })
        guard let inputData = try? JSONSerialization.data(withJSONObject: inputMap),
              let inputString = String(data: inputData, encoding: .utf8),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else {
            throw KiloUsageError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString),
        ]
        guard let url = components.url else { throw KiloUsageError.invalidResponse }
        return url
    }

    // MARK: - 解析

    private struct PassFields {
        let used: Double?
        let total: Double?
        let remaining: Double?
        let bonus: Double?
        let resetsAt: Date?
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw KiloUsageError.invalidResponse
        }

        let entriesByIndex = try responseEntriesByIndex(from: root)
        var payloadsByProcedure: [String: Any] = [:]

        for (index, procedure) in procedures.enumerated() {
            guard let entry = entriesByIndex[index] else { continue }
            if let mappedError = trpcError(from: entry) {
                guard isRequiredProcedure(procedure) else { continue }
                throw mappedError
            }
            if let payload = resultPayload(from: entry) {
                payloadsByProcedure[procedure] = payload
            }
        }

        let credit = creditFields(from: payloadsByProcedure[procedures[0]])
        let pass = passFields(from: payloadsByProcedure[procedures[1]])
        let planName = planName(from: payloadsByProcedure[procedures[1]])

        // 积分余额（credits）= providerCost。
        let cost = creditCost(used: credit.used, total: credit.total, remaining: credit.remaining)
        // Kilo Pass（$）= primary 窗口。
        let primary = passWindow(pass)

        return UsageSnapshot(primary: primary, providerCost: cost, planName: planName)
    }

    // 积分余额 → providerCost：used=已用、limit=总额度；若只有余额则 used=余额、limit=0（无上限）、period「余额」。
    private static func creditCost(used: Double?, total: Double?, remaining: Double?) -> ProviderCostSnapshot? {
        let resolvedTotal: Double? = if let total { max(0, total) }
        else if let used, let remaining { max(0, used + remaining) }
        else { nil }

        if let resolvedTotal {
            let resolvedUsed: Double = if let used {
                max(0, used)
            } else if let remaining {
                max(0, resolvedTotal - remaining)
            } else {
                0
            }
            return ProviderCostSnapshot(used: resolvedUsed, limit: resolvedTotal, currencyCode: "USD")
        }

        // 只有余额（remaining）而无总额度 → 展示余额、无上限。
        if let remaining {
            return ProviderCostSnapshot(used: max(0, remaining), limit: 0, currencyCode: "USD", period: L("余额"))
        }

        return nil
    }

    // Kilo Pass（$）→ 已用百分比窗口。有 passResetsAt 用之，否则无固定周期。
    private static func passWindow(_ pass: PassFields) -> RateWindow? {
        let resolvedTotal: Double? = if let total = pass.total { max(0, total) }
        else if let used = pass.used, let remaining = pass.remaining { max(0, used + remaining) }
        else { nil }

        guard let resolvedTotal else { return nil }

        let resolvedUsed: Double = if let used = pass.used {
            max(0, used)
        } else if let remaining = pass.remaining {
            max(0, resolvedTotal - remaining)
        } else {
            0
        }

        let percent: Double = resolvedTotal > 0
            ? min(100, max(0, resolvedUsed / resolvedTotal * 100))
            : 100
        return RateWindow(usedPercent: percent, resetsAt: pass.resetsAt)
    }

    // MARK: - tRPC batch 解析（照搬 CodexBar）

    private static func isRequiredProcedure(_ procedure: String) -> Bool {
        !optionalProcedures.contains(procedure)
    }

    private static func responseEntriesByIndex(from root: Any) throws -> [Int: [String: Any]] {
        if let entries = root as? [[String: Any]] {
            let limited = Array(entries.prefix(maxTopLevelEntries))
            return Dictionary(uniqueKeysWithValues: limited.enumerated().map { ($0.offset, $0.element) })
        }

        if let dictionary = root as? [String: Any] {
            if dictionary["result"] != nil || dictionary["error"] != nil {
                return [0: dictionary]
            }
            let indexedEntries = dictionary.compactMap { key, value -> (Int, [String: Any])? in
                guard let index = Int(key), let entry = value as? [String: Any] else { return nil }
                return (index, entry)
            }
            if !indexedEntries.isEmpty {
                let limitedEntries = indexedEntries.filter { $0.0 >= 0 && $0.0 < maxTopLevelEntries }
                return Dictionary(uniqueKeysWithValues: limitedEntries)
            }
        }

        throw KiloUsageError.invalidResponse
    }

    private static func trpcError(from entry: [String: Any]) -> KiloUsageError? {
        guard let errorObject = entry["error"] as? [String: Any] else { return nil }

        let code = stringValue(for: ["json", "data", "code"], in: errorObject)
            ?? stringValue(for: ["data", "code"], in: errorObject)
            ?? stringValue(for: ["code"], in: errorObject)
        let message = stringValue(for: ["json", "message"], in: errorObject)
            ?? stringValue(for: ["message"], in: errorObject)

        let combined = [code, message].compactMap { $0?.lowercased() }.joined(separator: " ")

        if combined.contains("unauthorized") || combined.contains("forbidden") {
            return .unauthorized
        }
        if combined.contains("not_found") || combined.contains("not found") {
            return .endpointNotFound
        }
        return .invalidResponse
    }

    private static func resultPayload(from entry: [String: Any]) -> Any? {
        guard let resultObject = entry["result"] as? [String: Any] else { return nil }

        if let dataObject = resultObject["data"] as? [String: Any] {
            if let jsonPayload = dataObject["json"] {
                if jsonPayload is NSNull { return nil }
                return jsonPayload
            }
            return dataObject
        }
        if let jsonPayload = resultObject["json"] {
            if jsonPayload is NSNull { return nil }
            return jsonPayload
        }
        return nil
    }

    private static func creditFields(from payload: Any?) -> (used: Double?, total: Double?, remaining: Double?) {
        guard let payload else { return (nil, nil, nil) }

        let contexts = dictionaryContexts(from: payload)
        let blocks = firstArray(forKeys: ["creditBlocks"], in: contexts)

        if let blocks {
            var totalFromBlocks: Double = 0
            var remainingFromBlocks: Double = 0
            var sawTotal = false
            var sawRemaining = false

            for case let block as [String: Any] in blocks {
                if let amountMicroUSD = double(from: block["amount_mUsd"]) {
                    totalFromBlocks += amountMicroUSD / 1_000_000
                    sawTotal = true
                }
                if let balanceMicroUSD = double(from: block["balance_mUsd"]) {
                    remainingFromBlocks += balanceMicroUSD / 1_000_000
                    sawRemaining = true
                }
            }

            if sawTotal || sawRemaining {
                let total = sawTotal ? max(0, totalFromBlocks) : nil
                let remaining = sawRemaining ? max(0, remainingFromBlocks) : nil
                let used: Double? = if let total, let remaining { max(0, total - remaining) } else { nil }
                return (used, total, remaining)
            }
        }

        let genericBlocks = firstArray(forKeys: ["blocks"], in: contexts)
        let blockContexts = (genericBlocks ?? []).compactMap { $0 as? [String: Any] }

        var used = firstDouble(
            forKeys: ["used", "usedCredits", "consumed", "spent", "creditsUsed"],
            in: blockContexts)
        var total = firstDouble(forKeys: ["total", "totalCredits", "creditsTotal", "limit"], in: blockContexts)
        var remaining = firstDouble(
            forKeys: ["remaining", "remainingCredits", "creditsRemaining"],
            in: blockContexts)

        if used == nil {
            used = firstDouble(forKeys: ["used", "usedCredits", "creditsUsed", "consumed", "spent"], in: contexts)
        }
        if total == nil {
            total = firstDouble(forKeys: ["total", "totalCredits", "creditsTotal", "limit"], in: contexts)
        }
        if remaining == nil {
            remaining = firstDouble(forKeys: ["remaining", "remainingCredits", "creditsRemaining"], in: contexts)
        }

        if total == nil, let used, let remaining {
            total = used + remaining
        }

        if used == nil, total == nil, remaining == nil,
           let balanceMilliUSD = firstDouble(forKeys: ["totalBalance_mUsd"], in: contexts),
           balanceMilliUSD == 0
        {
            // Kilo 对零余额账号可能返回空 creditBlocks，显式保留「耗尽」状态而非「无数据」。
            return (0, 0, 0)
        }

        if used == nil, total == nil, remaining == nil,
           let balanceMilliUSD = firstDouble(forKeys: ["totalBalance_mUsd"], in: contexts)
        {
            let balance = max(0, balanceMilliUSD / 1_000_000)
            return (max(0, 0), balance, balance)
        }

        return (used, total, remaining)
    }

    private static func passFields(from payload: Any?) -> PassFields {
        if let subscription = subscriptionData(from: payload) {
            let used = double(from: subscription["currentPeriodUsageUsd"]).map { max(0, $0) }
            let baseCredits = double(from: subscription["currentPeriodBaseCreditsUsd"]).map { max(0, $0) }
            let bonusCredits = max(0, double(from: subscription["currentPeriodBonusCreditsUsd"]) ?? 0)
            let total = baseCredits.map { $0 + bonusCredits }
            let remaining: Double? = if let total, let used { max(0, total - used) } else { nil }
            let resetsAt = date(from: subscription["nextBillingAt"])
                ?? date(from: subscription["nextRenewalAt"])
                ?? date(from: subscription["renewsAt"])
                ?? date(from: subscription["renewAt"])

            return PassFields(
                used: used,
                total: total,
                remaining: remaining,
                bonus: bonusCredits > 0 ? bonusCredits : nil,
                resetsAt: resetsAt)
        }
        return fallbackPassFields(from: payload)
    }

    private static func fallbackPassFields(from payload: Any?) -> PassFields {
        let contexts = dictionaryContexts(from: payload)
        guard !contexts.isEmpty else {
            return PassFields(used: nil, total: nil, remaining: nil, bonus: nil, resetsAt: nil)
        }

        var total = moneyAmount(
            centsKeys: [
                "amountCents", "totalCents", "planAmountCents", "monthlyAmountCents",
                "limitCents", "includedCents", "valueCents",
            ],
            milliUSDKeys: [
                "amount_mUsd", "total_mUsd", "planAmount_mUsd", "limit_mUsd", "included_mUsd", "value_mUsd",
            ],
            plainKeys: [
                "amount", "total", "limit", "included", "value", "creditsTotal", "totalCredits", "planAmount",
            ],
            in: contexts)
        var used = moneyAmount(
            centsKeys: ["usedCents", "spentCents", "consumedCents", "usedAmountCents", "consumedAmountCents"],
            milliUSDKeys: ["used_mUsd", "spent_mUsd", "consumed_mUsd", "usedAmount_mUsd"],
            plainKeys: ["used", "spent", "consumed", "usage", "creditsUsed", "usedAmount", "consumedAmount"],
            in: contexts)
        var remaining = moneyAmount(
            centsKeys: ["remainingCents", "remainingAmountCents", "availableCents", "leftCents", "balanceCents"],
            milliUSDKeys: ["remaining_mUsd", "available_mUsd", "left_mUsd", "balance_mUsd"],
            plainKeys: [
                "remaining", "available", "left", "balance", "creditsRemaining",
                "remainingAmount", "availableAmount",
            ],
            in: contexts)
        let bonus = moneyAmount(
            centsKeys: ["bonusCents", "bonusAmountCents", "includedBonusCents", "bonusRemainingCents"],
            milliUSDKeys: ["bonus_mUsd", "bonusAmount_mUsd"],
            plainKeys: ["bonus", "bonusAmount", "bonusCredits", "includedBonus"],
            in: contexts)
        let resetsAt = firstDate(
            forKeys: [
                "resetAt", "resetsAt", "nextResetAt", "renewAt", "renewsAt", "nextRenewalAt",
                "currentPeriodEnd", "periodEndsAt", "expiresAt", "expiryAt",
            ],
            in: contexts)

        if total == nil, let used, let remaining { total = used + remaining }
        if used == nil, let total, let remaining { used = max(0, total - remaining) }
        if remaining == nil, let total, let used { remaining = max(0, total - used) }

        return PassFields(used: used, total: total, remaining: remaining, bonus: bonus, resetsAt: resetsAt)
    }

    private static func planName(from payload: Any?) -> String? {
        if let subscription = subscriptionData(from: payload) {
            if let tier = string(from: subscription["tier"]) {
                let trimmed = tier.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return planNameForTier(trimmed) }
            }
            return "Kilo Pass"
        }

        let contexts = dictionaryContexts(from: payload)
        let candidates = [
            firstString(forKeys: ["planName", "tier", "tierName", "passName", "subscriptionName"], in: contexts),
            stringValue(for: ["plan", "name"], in: contexts),
            stringValue(for: ["subscription", "plan", "name"], in: contexts),
            stringValue(for: ["subscription", "name"], in: contexts),
            stringValue(for: ["pass", "name"], in: contexts),
            stringValue(for: ["state", "name"], in: contexts),
            stringValue(for: ["state"], in: contexts),
        ]
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        if let fallback = firstString(forKeys: ["name"], in: contexts), fallback.lowercased().contains("pass") {
            return fallback
        }
        return nil
    }

    private static func subscriptionData(from payload: Any?) -> [String: Any]? {
        guard let payloadDictionary = payload as? [String: Any] else { return nil }

        if let subscription = payloadDictionary["subscription"] as? [String: Any] { return subscription }
        if payloadDictionary["subscription"] is NSNull { return nil }

        let hasSubscriptionShape = payloadDictionary["currentPeriodUsageUsd"] != nil ||
            payloadDictionary["currentPeriodBaseCreditsUsd"] != nil ||
            payloadDictionary["currentPeriodBonusCreditsUsd"] != nil ||
            payloadDictionary["tier"] != nil
        return hasSubscriptionShape ? payloadDictionary : nil
    }

    private static func planNameForTier(_ tier: String) -> String {
        switch tier {
        case "tier_19": "Starter"
        case "tier_49": "Pro"
        case "tier_199": "Expert"
        default: tier
        }
    }

    // MARK: - 通用取值工具（照搬 CodexBar）

    private static func string(from raw: Any?) -> String? {
        raw as? String
    }

    private static func dictionaryContexts(from payload: Any?) -> [[String: Any]] {
        guard let payload, let dictionary = payload as? [String: Any] else { return [] }

        var contexts: [[String: Any]] = []
        var queue: [([String: Any], Int)] = [(dictionary, 0)]
        let maxDepth = 2

        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            contexts.append(current)
            guard depth < maxDepth else { continue }

            for value in current.values {
                if let nested = value as? [String: Any] {
                    queue.append((nested, depth + 1))
                    continue
                }
                if let nestedArray = value as? [Any] {
                    for case let nested as [String: Any] in nestedArray {
                        queue.append((nested, depth + 1))
                    }
                }
            }
        }
        return contexts
    }

    private static func firstArray(forKeys keys: [String], in contexts: [[String: Any]]) -> [Any]? {
        for context in contexts {
            for key in keys {
                if let values = context[key] as? [Any] { return values }
            }
        }
        return nil
    }

    private static func firstDouble(forKeys keys: [String], in contexts: [[String: Any]]) -> Double? {
        for context in contexts {
            for key in keys {
                if let value = double(from: context[key]) { return value }
            }
        }
        return nil
    }

    private static func firstString(forKeys keys: [String], in contexts: [[String: Any]]) -> String? {
        for context in contexts {
            for key in keys {
                if let value = context[key] as? String { return value }
            }
        }
        return nil
    }

    private static func firstDate(forKeys keys: [String], in contexts: [[String: Any]]) -> Date? {
        for context in contexts {
            for key in keys {
                if let value = date(from: context[key]) { return value }
            }
        }
        return nil
    }

    private static func moneyAmount(
        centsKeys: [String],
        milliUSDKeys: [String],
        plainKeys: [String],
        in contexts: [[String: Any]]) -> Double?
    {
        if let cents = firstDouble(forKeys: centsKeys, in: contexts) { return cents / 100 }
        if let milliUSD = firstDouble(forKeys: milliUSDKeys, in: contexts) { return milliUSD / 1_000_000 }
        return firstDouble(forKeys: plainKeys, in: contexts)
    }

    private static func stringValue(for path: [String], in dictionary: [String: Any]) -> String? {
        var cursor: Any = dictionary
        for key in path {
            guard let next = (cursor as? [String: Any])?[key] else { return nil }
            cursor = next
        }
        return cursor as? String
    }

    private static func stringValue(for path: [String], in contexts: [[String: Any]]) -> String? {
        for context in contexts {
            if let value = stringValue(for: path, in: context) { return value }
        }
        return nil
    }

    private static func double(from raw: Any?) -> Double? {
        switch raw {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }

    private static func date(from raw: Any?) -> Date? {
        switch raw {
        case let value as Date:
            return value
        case let value as Double:
            return dateFromEpoch(value)
        case let value as Int:
            return dateFromEpoch(Double(value))
        case let value as NSNumber:
            return dateFromEpoch(value.doubleValue)
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let numeric = Double(trimmed) { return dateFromEpoch(numeric) }

            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = withFractional.date(from: trimmed) { return parsed }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: trimmed)
        default:
            return nil
        }
    }

    private static func dateFromEpoch(_ value: Double) -> Date {
        let seconds = abs(value) > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}
