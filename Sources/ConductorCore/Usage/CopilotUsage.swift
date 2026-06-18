import Foundation
import SweetCookieKit

/// GitHub Copilot 用量取数。忠实摘自 CodexBar `Copilot` provider 的浏览器 cookie 路径
/// （`CopilotBudgetWebFetcher`，用 SweetCookieKit）：
///
///   1. 从浏览器取 github.com 的登录 cookie（要求至少含一个已知会话 cookie）。
///   2. `GET https://github.com/settings/billing/budgets`（HTML）→ 解析出 `X-Fetch-Nonce`。
///   3. 带 nonce + verified-fetch 头分页拉 `GET https://github.com/settings/billing/budgets?page=&page_size=10&scope=customer`（JSON）。
///   4. 挑出 Copilot 相关预算（按 product/sku/类型选择器匹配），按 `current/budget*100` 算已用百分比。
///
/// 说明：CodexBar 还有一条用 GitHub OAuth token 调 `api.github.com/copilot_internal/user`
/// 的配额路径，但那条不是 cookie 类、需要单独的 token 凭证，这里只移植浏览器 cookie 路径。
/// 预算接口本身不返回重置时刻，CodexBar 用「下个自然月 1 号」做展示近似，这里照搬。
///
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 无登录态/无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum CopilotUsageError: LocalizedError, Sendable {
    case noSession
    case notLoggedIn
    case server(Int)
    case invalidResponse
    case noBudget
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 GitHub 登录态，请在浏览器登录 github.com（Safari 需开启完全磁盘访问）")
        case .notLoggedIn: L("GitHub 浏览器登录态已失效，请重新登录 github.com")
        case let .server(c): L("GitHub 预算接口错误（%ld）", c)
        case .invalidResponse: L("GitHub 预算接口返回异常")
        case .noBudget: L("未找到可用的 Copilot 预算用量（请在 github.com/settings/billing/budgets 设置预算）")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum CopilotUsageFetcher {
    // CodexBar 的 cookie 域：github.com / www.github.com。
    private static let cookieDomains = ["github.com", "www.github.com"]
    // CodexBar CopilotGitHubCookieImporter.sessionCookieNames：要求至少命中其一才算有登录态。
    private static let sessionCookieNames: Set<String> = [
        "user_session",
        "__Host-user_session_same_site",
        "_gh_sess",
        "logged_in",
        "dotcom_user",
    ]

    private static let budgetsURLString = "https://github.com/settings/billing/budgets"

    // CodexBar 的 Copilot 预算选择器（归一后的标识）。
    private static let copilotProductID = "copilot"
    private static let copilotPremiumRequestSKU = "copilot_premium_request"
    private static let copilotAgentPremiumRequestSKU = "copilot_agent_premium_request"
    private static let sparkPremiumRequestSKU = "spark_premium_request"
    private static let copilotBudgetSelectors: Set<String> = [
        copilotProductID,
        copilotPremiumRequestSKU,
        copilotAgentPremiumRequestSKU,
        sparkPremiumRequestSKU,
    ]

    /// 是否能从浏览器拿到 GitHub 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 github.com 的 cookie，拼成 Cookie 头；要求至少含一个已知会话 cookie。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "copilot", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "copilot", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            guard cookies.contains(where: { sessionCookieNames.contains($0.name) }) else { continue }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }

    public static func fetch(session: URLSession = .shared) async throws -> CodexUsageSnapshot {
        guard let header = cookieHeader() else { throw CopilotUsageError.noSession }

        // 1) 先抓预算页 HTML，解析出 fetch nonce（CodexBar：拿不到 nonce 也尽力继续）。
        let nonce = try await fetchNonce(cookieHeader: header, session: session)

        // 2) 分页拉预算 JSON。
        var allBudgets: [Budget] = []
        var page = 1
        let maxPages = 20
        var shouldContinue = true
        while shouldContinue, page <= maxPages {
            let response = try await fetchBudgetPage(
                cookieHeader: header,
                nonce: nonce,
                page: page,
                session: session)
            allBudgets.append(contentsOf: response.budgets)
            shouldContinue = response.hasNextPage == true
            page += 1
        }

        return try makeSnapshot(from: allBudgets, now: Date())
    }

    // MARK: - 网络

    private static func fetchNonce(cookieHeader: String, session: URLSession) async throws -> String? {
        guard let url = URL(string: budgetsURLString) else { throw CopilotUsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Conductor", forHTTPHeaderField: "User-Agent")

        let (data, http) = try await perform(request, session: session)
        switch http.statusCode {
        case 200:
            guard let html = String(data: data, encoding: .utf8) else { throw CopilotUsageError.invalidResponse }
            return extractFetchNonce(from: html)
        case 401, 403:
            throw CopilotUsageError.notLoggedIn
        default:
            throw CopilotUsageError.server(http.statusCode)
        }
    }

    private static func fetchBudgetPage(
        cookieHeader: String,
        nonce: String?,
        page: Int,
        session: URLSession) async throws -> BudgetResponse
    {
        guard var components = URLComponents(string: budgetsURLString) else {
            throw CopilotUsageError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "page_size", value: "10"),
            URLQueryItem(name: "scope", value: "customer"),
        ]
        guard let url = components.url else { throw CopilotUsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(budgetsURLString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("true", forHTTPHeaderField: "GitHub-Verified-Fetch")
        request.setValue("Conductor", forHTTPHeaderField: "User-Agent")
        if let nonce, !nonce.isEmpty {
            request.setValue(nonce, forHTTPHeaderField: "X-Fetch-Nonce")
        }

        let (data, http) = try await perform(request, session: session)
        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(BudgetResponse.self, from: data)
            } catch {
                throw CopilotUsageError.invalidResponse
            }
        case 401, 403:
            throw CopilotUsageError.notLoggedIn
        default:
            throw CopilotUsageError.server(http.statusCode)
        }
    }

    private static func perform(
        _ request: URLRequest,
        session: URLSession) async throws -> (Data, HTTPURLResponse)
    {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CopilotUsageError.invalidResponse }
            return (data, http)
        } catch let e as CopilotUsageError {
            throw e
        } catch {
            throw CopilotUsageError.network(error.localizedDescription)
        }
    }

    // MARK: - nonce 解析（照搬 CodexBar 的多模式正则）

    static func extractFetchNonce(from html: String) -> String? {
        let patterns = [
            #"x-fetch-nonce"\s+content="([^"]+)""#,
            #"X-Fetch-Nonce"\s*:\s*"([^"]+)""#,
            #"fetchNonce"\s*:\s*"([^"]+)""#,
            #"data-fetch-nonce="([^"]+)""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  let nonceRange = Range(match.range(at: 1), in: html)
            else { continue }
            return String(html[nonceRange])
        }
        return nil
    }

    // MARK: - 预算 → 快照

    static func makeSnapshot(from budgets: [Budget], now: Date) throws -> CodexUsageSnapshot {
        let resetDate = approximateNextMonthResetDate(now: now)
        let windowSeconds = resetDate.map { max(1, Int($0.timeIntervalSince(now))) } ?? 30 * 24 * 3600

        let windows: [CodexUsageSnapshot.Window] = budgets.compactMap { budget in
            let selectors = normalizedSelectors(for: budget)
            guard isCopilotBudget(budget, selectors: selectors) else { return nil }
            // CodexBar：usedPercent = current/budget*100，封顶 999；这里再夹到 0...100 以适配 Int 窗口。
            let raw = budget.budgetAmount > 0
                ? min(999, max(0, budget.currentAmount / budget.budgetAmount * 100))
                : 0
            let used = Int(max(0, min(100, raw)).rounded())
            return CodexUsageSnapshot.Window(
                usedPercent: used,
                resetAt: resetDate ?? now.addingTimeInterval(TimeInterval(windowSeconds)),
                windowSeconds: windowSeconds)
        }

        guard !windows.isEmpty else { throw CopilotUsageError.noBudget }
        // 主预算 → session（会话位 / "Premium"），次预算 → weekly（"Chat"）。
        return CodexUsageSnapshot(
            planType: "Copilot",
            session: windows.first,
            weekly: windows.count > 1 ? windows[1] : nil)
    }

    private static func isCopilotBudget(_ budget: Budget, selectors: Set<String>) -> Bool {
        guard budget.budgetAmount > 0 else { return false }
        return !selectors.isDisjoint(with: copilotBudgetSelectors)
    }

    private static func normalizedSelectors(for budget: Budget) -> Set<String> {
        let values = budget.budgetProductSkus + [
            budget.budgetType,
            budget.budgetEntityName,
            budget.name,
        ].compactMap(\.self)
        return Set(values.compactMap(normalizedBillingIdentifier))
    }

    // CodexBar 的归一逻辑：把各种 sku/名称归到固定的 Copilot 标识。
    static func normalizedBillingIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let slug = slug(value)
        guard !slug.isEmpty else { return nil }
        let underscored = slug.replacingOccurrences(of: "-", with: "_")
        if underscored == copilotProductID {
            return copilotProductID
        }
        if underscored == "premium_request" || underscored == "premium_requests" {
            return copilotPremiumRequestSKU
        }
        if underscored == "coding_agent_premium_request" || underscored == "coding_agent_premium_requests" {
            return copilotAgentPremiumRequestSKU
        }
        if underscored.contains("spark"), underscored.contains("premium"), underscored.contains("request") {
            return sparkPremiumRequestSKU
        }
        if underscored.contains("cloud") || underscored.contains("coding"),
           underscored.contains("agent"),
           underscored.contains("premium"),
           underscored.contains("request")
        {
            return copilotAgentPremiumRequestSKU
        }
        if underscored.contains("bundled"), underscored.contains("premium"), underscored.contains("request") {
            return copilotPremiumRequestSKU
        }
        if underscored.contains("copilot"),
           underscored.contains("agent"),
           underscored.contains("premium"),
           underscored.contains("request")
        {
            return copilotAgentPremiumRequestSKU
        }
        if underscored.contains("copilot"), underscored.contains("premium"), underscored.contains("request") {
            return copilotPremiumRequestSKU
        }
        return underscored
    }

    private static func approximateNextMonthResetDate(now: Date) -> Date? {
        // GitHub 预算接口不返回重置时刻；CodexBar 用本地下个自然月 1 号做展示近似。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let monthStart = calendar.date(from: DateComponents(
            year: components.year,
            month: components.month,
            day: 1))
        else {
            return nil
        }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - 预算解码（照搬 CodexBar 的宽松解码：多套蛇形/驼峰键名 + payload 包裹 + 数字/字符串/对象金额）

    struct BudgetResponse: Decodable {
        let budgets: [Budget]
        let hasNextPage: Bool?

        private enum CodingKeys: String, CodingKey {
            case budgets
            case payload
            case hasNextPage
            case hasNextPageSnake = "has_next_page"
        }

        init(budgets: [Budget], hasNextPage: Bool? = nil) {
            self.budgets = budgets
            self.hasNextPage = hasNextPage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let payload = try container.decodeIfPresent(BudgetResponse.self, forKey: .payload) {
                self = payload
                return
            }
            self.budgets = try container.decodeIfPresent([Budget].self, forKey: .budgets) ?? []
            self.hasNextPage = try container.decodeIfPresent(Bool.self, forKey: .hasNextPage)
                ?? container.decodeIfPresent(Bool.self, forKey: .hasNextPageSnake)
        }
    }

    struct Budget: Decodable, Equatable {
        let id: String?
        let name: String?
        let budgetType: String?
        let budgetProductSkus: [String]
        let budgetScope: String?
        let budgetEntityName: String?
        let budgetAmount: Double
        let currentAmount: Double

        init(
            id: String? = nil,
            name: String? = nil,
            budgetType: String? = nil,
            budgetProductSkus: [String] = [],
            budgetScope: String? = nil,
            budgetEntityName: String? = nil,
            budgetAmount: Double,
            currentAmount: Double = 0)
        {
            self.id = id
            self.name = name
            self.budgetType = budgetType
            self.budgetProductSkus = budgetProductSkus
            self.budgetScope = budgetScope
            self.budgetEntityName = budgetEntityName
            self.budgetAmount = budgetAmount
            self.currentAmount = currentAmount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.id = Self.decodeString(container: container, keys: ["id", "uuid", "budget_id", "budgetId"])
            self.name = Self.decodeString(container: container, keys: ["name", "display_name", "displayName", "title"])
            self.budgetType = Self.decodeString(
                container: container,
                keys: ["budget_type", "budgetType", "type", "pricing_target_type", "pricingTargetType"])
            self.budgetProductSkus = Self.decodeStringArray(
                container: container,
                keys: [
                    "budget_product_skus",
                    "budgetProductSkus",
                    "budget_product_sku",
                    "budgetProductSku",
                    "product_skus",
                    "productSkus",
                    "skus",
                    "sku",
                    "product",
                    "product_name",
                    "productName",
                    "pricing_target_id",
                    "pricingTargetId",
                ])
            self.budgetScope = Self.decodeString(container: container, keys: ["budget_scope", "budgetScope", "scope"])
            self.budgetEntityName = Self.decodeString(
                container: container,
                keys: [
                    "budget_entity_name",
                    "budgetEntityName",
                    "entity_name",
                    "entityName",
                    "target_name",
                    "targetName",
                ])
            self.budgetAmount = Self.decodeDouble(
                container: container,
                keys: [
                    "budget_amount",
                    "budgetAmount",
                    "target_amount",
                    "targetAmount",
                    "spending_limit",
                    "spendingLimit",
                    "limit",
                    "amount",
                    "max",
                ]) ?? 0
            self.currentAmount = Self.decodeDouble(
                container: container,
                keys: [
                    "current_usage",
                    "currentUsage",
                    "current_amount",
                    "currentAmount",
                    "usage_amount",
                    "usageAmount",
                    "usage",
                    "spent",
                    "amount_used",
                    "amountUsed",
                ]) ?? 0
        }

        private static func decodeString(
            container: KeyedDecodingContainer<DynamicCodingKey>,
            keys: [String]) -> String?
        {
            for key in keys {
                guard let codingKey = DynamicCodingKey(key) else { continue }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey), !value.isEmpty {
                    return value
                }
                if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                    return String(value)
                }
            }
            return nil
        }

        private static func decodeStringArray(
            container: KeyedDecodingContainer<DynamicCodingKey>,
            keys: [String]) -> [String]
        {
            for key in keys {
                guard let codingKey = DynamicCodingKey(key) else { continue }
                if let values = try? container.decodeIfPresent([String].self, forKey: codingKey), !values.isEmpty {
                    return values
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey), !value.isEmpty {
                    return [value]
                }
                if let values = try? container.decodeIfPresent([ProductSKU].self, forKey: codingKey),
                   !values.isEmpty
                {
                    return values.flatMap(\.selectors)
                }
            }
            return []
        }

        private static func decodeDouble(
            container: KeyedDecodingContainer<DynamicCodingKey>,
            keys: [String]) -> Double?
        {
            for key in keys {
                guard let codingKey = DynamicCodingKey(key) else { continue }
                if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                    return value
                }
                if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                    return Double(value)
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
                   let parsed = Self.parseAmount(value)
                {
                    return parsed
                }
                if let value = try? container.decodeIfPresent(AmountValue.self, forKey: codingKey) {
                    return value.amount
                }
            }
            return nil
        }

        fileprivate static func parseAmount(_ value: String) -> Double? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let isNegative = trimmed.first == "-"
            guard !trimmed.dropFirst(isNegative ? 1 : 0).contains("-") else { return nil }
            let unsigned = trimmed.filter { $0.isNumber || $0 == "." }
            guard !unsigned.isEmpty else { return nil }
            return Double(isNegative ? "-\(unsigned)" : unsigned)
        }
    }

    private struct ProductSKU: Decodable, Equatable {
        let selectors: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.selectors = [
                "sku",
                "name",
                "display_name",
                "displayName",
                "product",
                "product_name",
                "productName",
            ].compactMap { key in
                guard let codingKey = DynamicCodingKey(key) else { return nil }
                return try? container.decodeIfPresent(String.self, forKey: codingKey)
            }
        }
    }

    private struct AmountValue: Decodable {
        let amount: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.amount = [
                "amount",
                "value",
                "total",
                "cents",
                "formatted",
            ].lazy.compactMap { key -> Double? in
                guard let codingKey = DynamicCodingKey(key) else { return nil }
                if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                    return key == "cents" ? value / 100 : value
                }
                if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                    return key == "cents" ? Double(value) / 100 : Double(value)
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey) {
                    return Budget.parseAmount(value)
                }
                return nil
            }.first
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(_ stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
