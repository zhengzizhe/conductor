import Foundation
import SweetCookieKit

/// Mistral（La Plateforme / admin 控制台）用量取数。忠实摘自 CodexBar `Mistral` provider 的
/// 浏览器 cookie 路径（用 SweetCookieKit）：从浏览器读 mistral.ai 的登录 cookie（需含 `ory_session_*`），
/// 调 `GET https://admin.mistral.ai/api/billing/v2/usage?month=&year=` 拿到「本月」各品类用量，
/// 用 prices 索引把 token/单位换算成花费（€），汇总为月度总花费。
///
/// 注意：Mistral 该接口只返回「本月花费」，没有任何额度/上限字段，所以无法算「已用百分比」；
/// 升级到富 `UsageSnapshot` 后，把月度花费写进 `providerCost`（used=已花、limit=0 表示无上限、
/// period=本月、resetsAt=账期结束），不再臆造 0% 窗口。首次读取 Chrome cookie 会弹一次「Chrome
/// 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum MistralUsageError: LocalizedError, Sendable {
    case noSession
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 Mistral 登录态，请在浏览器登录 admin.mistral.ai（Safari 需开启完全磁盘访问）")
        case .unauthorized: L("Mistral 登录态已失效或无效，请重新登录 admin.mistral.ai")
        case let .server(c): L("Mistral 接口错误（%ld）", c)
        case .invalidResponse: L("Mistral 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum MistralUsageFetcher {
    private static let baseURL = URL(string: "https://admin.mistral.ai")!
    // 照搬 CodexBar：mistral.ai / admin.mistral.ai / auth.mistral.ai 三域。
    private static let cookieDomains = ["mistral.ai", "admin.mistral.ai", "auth.mistral.ai"]

    /// 是否能从浏览器拿到 Mistral 登录 cookie（要求至少含一个 `ory_session_*`）。
    /// 注意：会触发一次浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        session() != nil
    }

    /// 跨默认浏览器顺序取 mistral 域 cookie，要求含 `ory_session_*` 会话 cookie；
    /// 返回拼好的 Cookie 头与（若有）`csrftoken` 值。
    static func session(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> (cookieHeader: String, csrfToken: String?)? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "mistral", env: env) {
            return (manual, nil)
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "mistral", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            guard cookies.contains(where: { $0.name.hasPrefix("ory_session_") }) else { continue }
            let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            let csrf = cookies.first { $0.name == "csrftoken" }?.value
            return (header, csrf)
        }
        return nil
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session urlSession: URLSession = .shared
    ) async throws -> UsageSnapshot {
        guard let creds = session(env: env) else { throw MistralUsageError.noSession }

        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)

        let usagePath = baseURL.appendingPathComponent("/api/billing/v2/usage")
        var components = URLComponents(url: usagePath, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "month", value: "\(month)"),
            URLQueryItem(name: "year", value: "\(year)"),
        ]
        guard let url = components.url else { throw MistralUsageError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(creds.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://admin.mistral.ai/organization/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrf = creds.csrfToken {
            request.setValue(csrf, forHTTPHeaderField: "X-CSRFTOKEN")
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await urlSession.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw MistralUsageError.invalidResponse }
            data = d; http = h
        } catch let e as MistralUsageError {
            throw e
        } catch {
            throw MistralUsageError.network(error.localizedDescription)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw MistralUsageError.unauthorized }
        guard http.statusCode == 200 else { throw MistralUsageError.server(http.statusCode) }
        return try parse(data, now: now)
    }

    // MARK: - 解析

    static func parse(_ data: Data, now: Date) throws -> UsageSnapshot {
        let billing: BillingResponse
        do { billing = try JSONDecoder().decode(BillingResponse.self, from: data) }
        catch { throw MistralUsageError.invalidResponse }

        // prices 索引：键 = "metric::group" → 单价。
        var prices: [String: Double] = [:]
        for price in billing.prices ?? [] {
            guard let metric = price.billingMetric,
                  let group = price.billingGroup,
                  let priceStr = price.price,
                  let value = Double(priceStr)
            else { continue }
            prices["\(metric)::\(group)"] = value
        }

        var totalCost: Double = 0

        // 各品类汇总花费（completion / ocr / connectors / audio）。
        for category in [billing.completion, billing.ocr, billing.connectors, billing.audio] {
            for (_, modelData) in category?.models ?? [:] {
                totalCost += cost(of: modelData, prices: prices)
            }
        }
        // libraries_api（pages + tokens）。
        for category in [billing.librariesApi?.pages, billing.librariesApi?.tokens] {
            for (_, modelData) in category?.models ?? [:] {
                totalCost += cost(of: modelData, prices: prices)
            }
        }
        // fine_tuning（training + storage）。
        for models in [billing.fineTuning?.training, billing.fineTuning?.storage] {
            for (_, modelData) in models ?? [:] {
                totalCost += cost(of: modelData, prices: prices)
            }
        }

        let currency = billing.currency ?? "EUR"
        let end = billing.endDate.flatMap { parseDate($0) }

        // 该接口只返回「本月花费」、无任何额度上限字段 → 花费走 providerCost（limit=0 表示无上限），
        // 不臆造任何 usedPercent 窗口。负数（退款/抵扣）夹到 0，避免菜单栏显示负值。
        let spend = max(0, totalCost)
        let providerCost = ProviderCostSnapshot(
            used: spend,
            limit: 0,
            currencyCode: currency,
            period: L("本月"),
            resetsAt: end)
        return UsageSnapshot(providerCost: providerCost, updatedAt: now)
    }

    /// 单个 model 的花费：input/output/cached 三组里，每条 `value_paid ?? value` 单位 × 对应单价之和。
    private static func cost(of data: ModelUsageData, prices: [String: Double]) -> Double {
        var total: Double = 0
        for entries in [data.input, data.output, data.cached] {
            for entry in entries ?? [] {
                let units = entry.valuePaid ?? entry.value ?? 0
                guard let metric = entry.billingMetric, let group = entry.billingGroup else { continue }
                total += Double(units) * (prices["\(metric)::\(group)"] ?? 0)
            }
        }
        return total
    }

    private static func parseDate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    // MARK: - API 响应模型（字段名忠实照搬 CodexBar MistralModels）

    private struct BillingResponse: Decodable {
        let completion: ModelUsageCategory?
        let ocr: ModelUsageCategory?
        let connectors: ModelUsageCategory?
        let librariesApi: LibrariesUsageCategory?
        let fineTuning: FineTuningCategory?
        let audio: ModelUsageCategory?
        let startDate: String?
        let endDate: String?
        let currency: String?
        let currencySymbol: String?
        let prices: [Price]?

        enum CodingKeys: String, CodingKey {
            case completion, ocr, connectors, audio, currency, prices
            case librariesApi = "libraries_api"
            case fineTuning = "fine_tuning"
            case startDate = "start_date"
            case endDate = "end_date"
            case currencySymbol = "currency_symbol"
        }
    }

    private struct ModelUsageCategory: Decodable {
        let models: [String: ModelUsageData]?
    }

    private struct LibrariesUsageCategory: Decodable {
        let pages: ModelUsageCategory?
        let tokens: ModelUsageCategory?
    }

    private struct FineTuningCategory: Decodable {
        let training: [String: ModelUsageData]?
        let storage: [String: ModelUsageData]?
    }

    private struct ModelUsageData: Decodable {
        let input: [UsageEntry]?
        let output: [UsageEntry]?
        let cached: [UsageEntry]?
    }

    private struct UsageEntry: Decodable {
        let billingMetric: String?
        let billingGroup: String?
        let value: Int?
        let valuePaid: Int?

        enum CodingKeys: String, CodingKey {
            case value
            case billingMetric = "billing_metric"
            case billingGroup = "billing_group"
            case valuePaid = "value_paid"
        }
    }

    private struct Price: Decodable {
        let billingMetric: String?
        let billingGroup: String?
        let price: String?

        enum CodingKeys: String, CodingKey {
            case price
            case billingMetric = "billing_metric"
            case billingGroup = "billing_group"
        }
    }
}
