import CryptoKit
import Foundation

/// AWS Bedrock 用量取数。忠实摘自 CodexBar `Bedrock` provider（token/凭证 env 路径，无 cookie）：
/// 读环境变量 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`（可选 `AWS_SESSION_TOKEN`、`AWS_REGION`/
/// `AWS_DEFAULT_REGION`），用 AWS SigV4 对 Cost Explorer（`https://ce.us-east-1.amazonaws.com`）发一次
/// `GetCostAndUsage`（X-Amz-Target: `AWSInsightsIndexService.GetCostAndUsage`），按 SERVICE 维度分组、
/// 取本月 `UnblendedCost` 中服务名含「Bedrock」的金额合计，得到本月消费。配合可选预算
/// `CODEXBAR_BEDROCK_BUDGET` 折算成「已用百分比」。账号级（与具体 CLI 无关）。
///
/// 凭证来源（与 CodexBar `BedrockSettingsReader` 完全一致）：
/// - 静态密钥（keys 模式）：`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`（+ 可选 `AWS_SESSION_TOKEN`）。
///   本路径只用 Foundation + CryptoKit 做 SigV4 签名，**不依赖** AWS SDK 或 AWS CLI。
/// - 配置档（profile 模式）：`AWS_PROFILE`。CodexBar 此路径必须 shell-out `aws configure
///   export-credentials` 子进程解析 SSO/assume-role 凭证 —— 这依赖外部 AWS CLI，**不在本转写范围内**，
///   遇到时抛 `.unsupported`、`hasCredentials` 不把它算作可用。
///
/// 注意：Cost Explorer 不暴露「限流窗口/重置」概念，只有月度账单金额。因此快照以
/// `providerCost`（本月消费 $ + 可选预算上限，period="Monthly"、resetsAt=本月月末）为主：
/// - 配置了 `CODEXBAR_BEDROCK_BUDGET`（>0）：额外给一个 primary 窗，usedPercent = 消费/预算*100，
///   resetsAt=本月月末（对应 CodexBar 的 "Monthly budget" 窗）。
/// - 未配置预算：providerCost.limit=0（无上限，仅显示已用金额），无 primary 窗。
/// 环境变量、签名算法、Cost Explorer 请求体与解析逻辑均与 CodexBar 对应实现一一对应。
public enum BedrockUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    /// profile 模式（`AWS_PROFILE`）依赖外部 AWS CLI 子进程，本转写不支持。
    case unsupported
    case server(Int)
    case invalidResponse
    case apiError(String)
    case parseFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            L("未配置 AWS 凭证，请设置环境变量 AWS_ACCESS_KEY_ID 与 AWS_SECRET_ACCESS_KEY")
        case .unsupported:
            L("AWS Bedrock 的 profile（AWS_PROFILE）模式需要外部 AWS CLI 子进程，暂不支持；请改用 AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY 静态密钥")
        case let .server(code):
            L("AWS Cost Explorer 接口错误（%ld）", code)
        case .invalidResponse:
            L("AWS Cost Explorer 用量接口返回异常")
        case let .apiError(m):
            L("AWS Cost Explorer API 错误：%@", m)
        case let .parseFailed(m):
            L("解析 AWS Cost Explorer 响应失败：%@", m)
        case let .network(m):
            L("网络错误：%@", m)
        }
    }
}

public enum BedrockUsageFetcher {
    // MARK: - 环境变量键（与 CodexBar BedrockSettingsReader 对齐）

    static let accessKeyIDKey = "AWS_ACCESS_KEY_ID"
    static let secretAccessKeyKey = "AWS_SECRET_ACCESS_KEY"
    static let sessionTokenKey = "AWS_SESSION_TOKEN"
    static let regionKeys = ["AWS_REGION", "AWS_DEFAULT_REGION"]
    static let budgetKey = "CODEXBAR_BEDROCK_BUDGET"
    static let apiURLKey = "CODEXBAR_BEDROCK_API_URL"
    static let profileKey = "AWS_PROFILE"
    static let authModeKey = "CODEXBAR_BEDROCK_AUTH_MODE"
    static let defaultRegion = "us-east-1"

    private static let requestTimeoutSeconds: TimeInterval = 15

    /// 鉴权模式（与 CodexBar `BedrockSettingsReader.authMode` 一致）。
    enum AuthMode: String {
        case keys
        case profile
    }

    // MARK: - 凭证可用性

    /// 是否配置了可用的（静态密钥）凭证。profile 模式因依赖外部 AWS CLI 子进程，本转写不支持，
    /// 故只在 keys 模式且静态密钥齐全时算作可用。
    public static func hasCredentials(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch authMode(env: env) {
        case .keys:
            hasStaticKeys(env: env)
        case .profile:
            false
        }
    }

    // MARK: - 设置读取（忠实摘自 CodexBar BedrockSettingsReader）

    static func accessKeyID(env: [String: String]) -> String? { cleaned(env[accessKeyIDKey]) }
    static func secretAccessKey(env: [String: String]) -> String? { cleaned(env[secretAccessKeyKey]) }
    static func sessionToken(env: [String: String]) -> String? { cleaned(env[sessionTokenKey]) }

    static func region(env: [String: String]) -> String {
        for key in regionKeys {
            if let value = cleaned(env[key]) { return value }
        }
        return defaultRegion
    }

    static func budget(env: [String: String]) -> Double? {
        guard let raw = cleaned(env[budgetKey]), let value = Double(raw), value > 0 else { return nil }
        return value
    }

    static func profile(env: [String: String]) -> String? { cleaned(env[profileKey]) }

    static func authMode(env: [String: String]) -> AuthMode {
        if let raw = cleaned(env[authModeKey])?.lowercased(), let mode = AuthMode(rawValue: raw) {
            return mode
        }
        if profile(env: env) != nil, !hasStaticKeys(env: env) {
            return .profile
        }
        return .keys
    }

    static func hasStaticKeys(env: [String: String]) -> Bool {
        accessKeyID(env: env) != nil && secretAccessKey(env: env) != nil
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        // profile 模式依赖外部 AWS CLI 子进程，本转写不支持。
        guard authMode(env: env) == .keys else { throw BedrockUsageError.unsupported }
        guard let accessKeyID = accessKeyID(env: env),
              let secretAccessKey = secretAccessKey(env: env)
        else {
            throw BedrockUsageError.missingCredentials
        }

        let credentials = Credentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken(env: env))

        let spend = try await fetchMonthlyCost(credentials: credentials, env: env, session: session)
        let budget = budget(env: env)
        return makeSnapshot(spend: spend, budget: budget)
    }

    /// 把本月消费 + 可选预算组装成富用量快照。
    /// - providerCost：忠实搬自 CodexBar `BedrockUsageStats` 的 `cost`（used=本月消费、limit=预算 ?? 0、
    ///   currencyCode="USD"、period="Monthly"、resetsAt=本月月末）；limit<=0 时只展示已用金额。
    /// - primary 窗：仅当配置了预算（>0）时才有，usedPercent = min(100, 消费/预算*100)，
    ///   resetsAt=本月月末，对应 CodexBar 的 "Monthly budget" 窗。
    static func makeSnapshot(spend: Double, budget: Double?) -> UsageSnapshot {
        let monthEnd = endOfCurrentMonth()

        let primary: RateWindow? = if let budget, budget > 0 {
            RateWindow(
                title: L("本月预算"),
                usedPercent: spend / budget * 100,
                resetsAt: monthEnd,
                resetDescription: "Monthly budget")
        } else {
            nil
        }

        let cost = ProviderCostSnapshot(
            used: spend,
            limit: budget ?? 0,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: monthEnd)

        return UsageSnapshot(
            primary: primary,
            providerCost: cost)
    }

    // MARK: - 月度消费（忠实摘自 CodexBar BedrockUsageFetcher.fetchMonthlyCost）

    private static func fetchMonthlyCost(
        credentials: Credentials,
        env: [String: String],
        session: URLSession) async throws -> Double
    {
        let (startDate, endDate) = currentMonthRange()
        let pages = try await callCostExplorerPages(
            startDate: startDate,
            endDate: endDate,
            granularity: "MONTHLY",
            credentials: credentials,
            env: env,
            session: session)
        return try parseTotalCost(pages)
    }

    private struct CostExplorerQuery {
        let startDate: String
        let endDate: String
        let granularity: String
        let nextPageToken: String?
    }

    private static func callCostExplorerPages(
        startDate: String,
        endDate: String,
        granularity: String,
        credentials: Credentials,
        env: [String: String],
        session: URLSession) async throws -> [Data]
    {
        var pages: [Data] = []
        var nextPageToken: String?
        var seenPageTokens: Set<String> = []

        repeat {
            let page = try await callCostExplorerPage(
                query: CostExplorerQuery(
                    startDate: startDate,
                    endDate: endDate,
                    granularity: granularity,
                    nextPageToken: nextPageToken),
                credentials: credentials,
                env: env,
                session: session)
            pages.append(page)
            nextPageToken = try self.nextPageToken(from: page)
            if let nextPageToken, !seenPageTokens.insert(nextPageToken).inserted {
                throw BedrockUsageError.parseFailed("Cost Explorer returned repeated NextPageToken")
            }
        } while nextPageToken != nil

        return pages
    }

    private static func callCostExplorerPage(
        query: CostExplorerQuery,
        credentials: Credentials,
        env: [String: String],
        session: URLSession) async throws -> Data
    {
        let ceRegion = "us-east-1"
        let baseURL: URL = if let override = env[apiURLKey],
                              let url = URL(string: cleaned(override) ?? "")
        {
            url
        } else {
            URL(string: "https://ce.\(ceRegion).amazonaws.com")!
        }

        var requestBody: [String: Any] = [
            "TimePeriod": [
                "Start": query.startDate,
                "End": query.endDate,
            ],
            "Granularity": query.granularity,
            "Metrics": ["UnblendedCost"],
            "GroupBy": [
                ["Type": "DIMENSION", "Key": "SERVICE"],
            ],
        ]
        if let nextPageToken = query.nextPageToken {
            requestBody["NextPageToken"] = nextPageToken
        }

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSInsightsIndexService.GetCostAndUsage", forHTTPHeaderField: "X-Amz-Target")
        request.timeoutInterval = requestTimeoutSeconds

        AWSSigner.sign(request: &request, credentials: credentials, region: ceRegion, service: "ce")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw BedrockUsageError.invalidResponse }
            data = d
            http = h
        } catch let error as BedrockUsageError {
            throw error
        } catch {
            throw BedrockUsageError.network(error.localizedDescription)
        }

        guard http.statusCode == 200 else {
            // Cost Explorer 在账户当月无数据时返回 400 DataUnavailableException，视作零消费。
            if isDataUnavailableResponse(statusCode: http.statusCode, data: data) {
                return Data(#"{"ResultsByTime":[]}"#.utf8)
            }
            throw BedrockUsageError.server(http.statusCode)
        }

        return data
    }

    private static func nextPageToken(from data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BedrockUsageError.parseFailed("Invalid Cost Explorer response")
        }
        return cleaned(json["NextPageToken"] as? String)
    }

    private static func parseTotalCost(_ pages: [Data]) throws -> Double {
        var total = 0.0
        for page in pages {
            total += try parseTotalCost(page)
        }
        return total
    }

    private static func parseTotalCost(_ data: Data) throws -> Double {
        var total = 0.0
        for (_, cost, _) in try parseGroupedResults(data) {
            total += cost
        }
        return total
    }

    private static func parseGroupedResults(_ data: Data) throws
        -> [(service: String, cost: Double, date: String)]
    {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["ResultsByTime"] as? [[String: Any]]
        else {
            throw BedrockUsageError.parseFailed("Missing ResultsByTime in Cost Explorer response")
        }

        var items: [(service: String, cost: Double, date: String)] = []
        for result in results {
            let dateStr = (result["TimePeriod"] as? [String: String])?["Start"] ?? ""
            guard let groups = result["Groups"] as? [[String: Any]] else { continue }
            for group in groups {
                guard let keys = group["Keys"] as? [String],
                      let serviceName = keys.first,
                      serviceName.localizedCaseInsensitiveContains("Bedrock")
                else { continue }

                if let metrics = group["Metrics"] as? [String: Any],
                   let unblended = metrics["UnblendedCost"] as? [String: Any],
                   let amountStr = unblended["Amount"] as? String,
                   let amount = Double(amountStr)
                {
                    items.append((serviceName, amount, dateStr))
                }
            }
        }
        return items
    }

    private static func isDataUnavailableResponse(statusCode: Int, data: Data) -> Bool {
        guard statusCode == 400,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        let nestedError = json["Error"] as? [String: Any]
        let candidates = [
            json["__type"],
            json["code"],
            json["Code"],
            nestedError?["Code"],
        ]
        return candidates.compactMap { $0 as? String }.contains { rawCode in
            rawCode.split(separator: "#").last == "DataUnavailableException"
        }
    }

    // MARK: - 日期工具（忠实摘自 CodexBar BedrockUsageFetcher）

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func currentMonthRange(now: Date = Date()) -> (start: String, end: String) {
        let calendar = utcCalendar()
        let components = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: components)!

        let formatter = dateFormatter()
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        return (formatter.string(from: startOfMonth), formatter.string(from: tomorrow))
    }

    private static func endOfCurrentMonth() -> Date? {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: Date()) else { return nil }
        let components = calendar.dateComponents([.year, .month], from: Date())
        guard let startOfMonth = calendar.date(from: components) else { return nil }
        return calendar.date(byAdding: .day, value: range.count, to: startOfMonth)
    }

    // MARK: - 凭证

    struct Credentials: Sendable {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String?
    }
}

// MARK: - AWS SigV4 签名（忠实摘自 CodexBar BedrockAWSSigner，只用 Foundation + CryptoKit）

private enum AWSSigner {
    static func sign(
        request: inout URLRequest,
        credentials: BedrockUsageFetcher.Credentials,
        region: String,
        service: String,
        date: Date = Date())
    {
        let dateFormatter = self.dateFormatter()
        let dateStamp = self.dateStamp(date: date)
        let amzDate = dateFormatter.string(from: date)

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let sessionToken = credentials.sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let host = request.url?.host ?? ""
        request.setValue(host, forHTTPHeaderField: "Host")

        let bodyHash = self.sha256Hex(request.httpBody ?? Data())
        request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")

        let signedHeaders = self.signedHeaders(request: request)
        let canonicalRequest = self.canonicalRequest(
            request: request,
            signedHeaders: signedHeaders,
            bodyHash: bodyHash)

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = self.calculateSignature(
            secretKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service,
            stringToSign: stringToSign)

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders.keys), "
            + "Signature=\(signature)"

        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private struct SignedHeadersInfo {
        let keys: String
        let canonical: String
    }

    private static func signedHeaders(request: URLRequest) -> SignedHeadersInfo {
        var headers: [(String, String)] = []
        if let allHeaders = request.allHTTPHeaderFields {
            for (key, value) in allHeaders {
                headers.append((key.lowercased(), value.trimmingCharacters(in: .whitespaces)))
            }
        }
        headers.sort { $0.0 < $1.0 }

        let keys = headers.map(\.0).joined(separator: ";")
        let canonical = headers.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        return SignedHeadersInfo(keys: keys, canonical: canonical)
    }

    private static func canonicalRequest(
        request: URLRequest,
        signedHeaders: SignedHeadersInfo,
        bodyHash: String) -> String
    {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let path = url.path.isEmpty ? "/" : url.path
        let query = self.canonicalQueryString(url: url)

        return [
            method,
            self.uriEncodePath(path),
            query,
            signedHeaders.canonical + "\n",
            signedHeaders.keys,
            bodyHash,
        ].joined(separator: "\n")
    }

    private static func canonicalQueryString(url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else {
            return ""
        }

        return queryItems
            .map { item in
                let key = self.uriEncode(item.name)
                let value = self.uriEncode(item.value ?? "")
                return "\(key)=\(value)"
            }
            .sorted()
            .joined(separator: "&")
    }

    private static func calculateSignature(
        secretKey: String,
        dateStamp: String,
        region: String,
        service: String,
        stringToSign: String) -> String
    {
        let kDate = self.hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = self.hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = self.hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = self.hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = self.hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private static func dateStamp(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func uriEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func uriEncodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { self.uriEncode(String($0)) }
            .joined(separator: "/")
    }
}
