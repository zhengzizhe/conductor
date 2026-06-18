import Foundation

/// Vertex AI（Google Cloud / Vertex AI）用量取数。忠实转写自 CodexBar 的 `VertexAI` provider
/// （`VertexAIOAuthCredentialsStore` / `VertexAITokenRefresher` / `VertexAIUsageFetcher`），
/// 自足、不依赖浏览器 cookie：
/// 1. 读 gcloud Application Default Credentials
///    （`$GOOGLE_APPLICATION_CREDENTIALS` → `$CLOUDSDK_CONFIG/application_default_credentials.json`
///    → `~/.config/gcloud/application_default_credentials.json`）的 OAuth 用户凭证
///    （`client_id` / `client_secret` / `refresh_token`）；
/// 2. 用 `refresh_token` 走 `https://oauth2.googleapis.com/token` 刷新 access token；
/// 3. 查 Cloud Monitoring `v3/projects/{project}/timeSeries`，拉
///    `serviceruntime.googleapis.com/quota/allocation/usage` 与 `.../quota/limit` 两组时间序列，
///    按 (quota_metric, limit_name, location) 配对，取 `max(usage/limit)*100` 作为已用百分比。
///
/// 复用 `CodexUsageSnapshot` 作为通用「会话/周」形状：Vertex 配额没有清晰的会话/周划分，
/// CodexBar 也只产出单一「requests」百分比且无重置周期，故归并为 **session** 窗口
/// （`reset = now + 30 天`、`windowSeconds = 0`），`weekly = nil`。
///
/// 凭证来源：`gcloud auth application-default login` 写入的 ADC 文件。
/// 环境变量覆盖：`GOOGLE_APPLICATION_CREDENTIALS`（凭证文件）、`CLOUDSDK_CONFIG`（gcloud 配置目录）、
/// `GOOGLE_CLOUD_PROJECT` / `GCLOUD_PROJECT` / `CLOUDSDK_CORE_PROJECT`（项目 ID 回退）。
///
/// 说明：CodexBar 还支持「服务账号」凭证（`client_email`/`private_key`），它通过 shell 调
/// `gcloud auth application-default print-access-token` 取 token。该路径需要外部进程，
/// 不符合「只用 Foundation」约束，故此处只实现纯 Foundation 的用户凭证（refresh token）路径，
/// 检测到服务账号凭证时抛 `.unsupportedServiceAccount`。
public enum VertexAIUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case unsupportedServiceAccount
    case missingClientCredentials
    case missingTokens
    case noProject
    case unauthorized
    case forbidden
    case refreshExpired
    case server(Int)
    case invalidResponse
    case noData
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            L("未找到 gcloud 登录信息，请先运行 `gcloud auth application-default login`")
        case .unsupportedServiceAccount:
            L("Vertex AI 当前为服务账号凭证，仅支持用户凭证（gcloud auth application-default login）")
        case .missingClientCredentials:
            L("gcloud 凭证缺少 client_id 或 client_secret")
        case .missingTokens:
            L("gcloud 凭证中没有可用的令牌")
        case .noProject:
            L("未配置 Google Cloud 项目，请运行 `gcloud config set project PROJECT_ID`")
        case .unauthorized:
            L("Vertex AI 令牌已过期，请重新运行 `gcloud auth application-default login`")
        case .forbidden:
            L("访问被拒绝，请检查 Cloud Monitoring 的 IAM 权限")
        case .refreshExpired:
            L("刷新令牌已失效，请重新运行 `gcloud auth application-default login`")
        case let .server(code):
            L("Vertex AI 接口错误（%ld）", code)
        case .invalidResponse:
            L("Vertex AI 用量接口返回异常")
        case .noData:
            L("当前项目未找到 Vertex AI 用量数据")
        case let .network(msg):
            L("网络错误：%@", msg)
        }
    }
}

public enum VertexAIUsageFetcher {
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let monitoringEndpoint = "https://monitoring.googleapis.com/v3/projects"
    private static let usageWindowSeconds: TimeInterval = 24 * 60 * 60
    private static let noPeriodSeconds: TimeInterval = 30 * 24 * 60 * 60

    /// 是否存在 gcloud ADC 凭证文件（用于决定账号用量区是否展示该 provider）。
    /// 仅做廉价的本地文件存在性检查，不发网络。
    public static func hasCredentials(
        env: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let url = credentialsFileURL(env: env)
        return FileManager.default.fileExists(atPath: url.path)
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        var creds = try loadCredentials(env: env)

        // 过期则用 refresh token 刷新（提前 5 分钟刷新，与 CodexBar 一致）。
        if creds.needsRefresh {
            creds = try await refresh(creds, session: session)
        }

        guard let projectId = creds.projectId, !projectId.isEmpty else {
            throw VertexAIUsageError.noProject
        }

        let usedPercent = try await fetchQuotaUsedPercent(
            accessToken: creds.accessToken,
            projectId: projectId,
            session: session)

        // Vertex 配额无清晰周期：归并为单一 session 窗口，reset = now + 30 天，weekly = nil。
        let clamped = max(0, min(100, Int(usedPercent.rounded())))
        let window = CodexUsageSnapshot.Window(
            usedPercent: clamped,
            resetAt: Date().addingTimeInterval(noPeriodSeconds),
            windowSeconds: 0)
        return CodexUsageSnapshot(planType: nil, session: window, weekly: nil)
    }

    // MARK: - 凭证

    private struct Credentials {
        var accessToken: String
        let refreshToken: String
        let clientId: String
        let clientSecret: String
        let projectId: String?
        var expiryDate: Date?

        var needsRefresh: Bool {
            guard let expiryDate else { return true }
            // Refresh 5 minutes before expiry.
            return Date().addingTimeInterval(300) > expiryDate
        }
    }

    private static func credentialsFileURL(env: [String: String]) -> URL {
        if let path = env["GOOGLE_APPLICATION_CREDENTIALS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let configDir = env["CLOUDSDK_CONFIG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configDir.isEmpty
        {
            return URL(fileURLWithPath: configDir)
                .appendingPathComponent("application_default_credentials.json")
        }
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("gcloud")
            .appendingPathComponent("application_default_credentials.json")
    }

    private static func projectConfigURL(env: [String: String]) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let configDir = env["CLOUDSDK_CONFIG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configDir.isEmpty
        {
            return URL(fileURLWithPath: configDir)
                .appendingPathComponent("configurations")
                .appendingPathComponent("config_default")
        }
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("gcloud")
            .appendingPathComponent("configurations")
            .appendingPathComponent("config_default")
    }

    private static func loadCredentials(env: [String: String]) throws -> Credentials {
        let url = credentialsFileURL(env: env)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { throw VertexAIUsageError.notLoggedIn }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VertexAIUsageError.invalidResponse
        }

        // 服务账号凭证（client_email + private_key）需要外部 gcloud 取 token，本实现不支持。
        if let email = (json["client_email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty,
           let key = (json["private_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty
        {
            throw VertexAIUsageError.unsupportedServiceAccount
        }

        // 用户凭证（gcloud auth application-default login）。
        guard let clientId = json["client_id"] as? String,
              let clientSecret = json["client_secret"] as? String
        else { throw VertexAIUsageError.missingClientCredentials }

        guard let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw VertexAIUsageError.missingTokens
        }

        // access token 文件里可能没有，刷新即可补上。
        let accessToken = json["access_token"] as? String ?? ""

        let projectId = loadProjectId(env: env)

        var expiryDate: Date?
        if let expiryStr = json["token_expiry"] as? String {
            expiryDate = ISO8601DateFormatter().date(from: expiryStr)
        }

        return Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            clientId: clientId,
            clientSecret: clientSecret,
            projectId: projectId,
            expiryDate: expiryDate)
    }

    private static func loadProjectId(env: [String: String]) -> String? {
        func fromEnv() -> String? {
            for key in ["GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT"] {
                if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    return v
                }
            }
            return nil
        }

        let configURL = projectConfigURL(env: env)
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return fromEnv()
        }

        // 解析 INI 风格配置里的 `project = ...`。
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("project") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { return value }
                }
            }
        }
        return fromEnv()
    }

    // MARK: - Token 刷新

    private static func refresh(
        _ credentials: Credentials,
        session: URLSession) async throws -> Credentials
    {
        guard !credentials.refreshToken.isEmpty else {
            throw VertexAIUsageError.missingTokens
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
            "refresh_token": credentials.refreshToken,
            "grant_type": "refresh_token",
        ]
        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw VertexAIUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as VertexAIUsageError {
            throw e
        } catch {
            throw VertexAIUsageError.network(error.localizedDescription)
        }

        if http.statusCode == 400 || http.statusCode == 401 {
            let errorCode = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            switch errorCode?.lowercased() {
            case "invalid_grant", "unauthorized_client":
                throw VertexAIUsageError.refreshExpired
            default:
                throw VertexAIUsageError.refreshExpired
            }
        }
        guard http.statusCode == 200 else { throw VertexAIUsageError.server(http.statusCode) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String
        else { throw VertexAIUsageError.invalidResponse }

        let expiresIn = json["expires_in"] as? Double ?? 3600
        var updated = credentials
        updated.accessToken = newAccessToken
        updated.expiryDate = Date().addingTimeInterval(expiresIn)
        return updated
    }

    // MARK: - Cloud Monitoring 配额查询

    private struct QuotaKey: Hashable {
        let quotaMetric: String
        let limitName: String
        let location: String
    }

    private struct MonitoringTimeSeriesResponse: Decodable {
        let timeSeries: [MonitoringTimeSeries]?
        let nextPageToken: String?
    }

    private struct MonitoringTimeSeries: Decodable {
        let metric: MonitoringMetric
        let resource: MonitoringResource
        let points: [MonitoringPoint]
    }

    private struct MonitoringMetric: Decodable {
        let type: String?
        let labels: [String: String]?
    }

    private struct MonitoringResource: Decodable {
        let type: String?
        let labels: [String: String]?
    }

    private struct MonitoringPoint: Decodable {
        let value: MonitoringValue
    }

    private struct MonitoringValue: Decodable {
        let doubleValue: Double?
        let int64Value: String?
    }

    private static func fetchQuotaUsedPercent(
        accessToken: String,
        projectId: String,
        session: URLSession) async throws -> Double
    {
        let usageFilter = """
        metric.type="serviceruntime.googleapis.com/quota/allocation/usage" \
        AND resource.type="consumer_quota" \
        AND resource.label.service="aiplatform.googleapis.com"
        """
        let limitFilter = """
        metric.type="serviceruntime.googleapis.com/quota/limit" \
        AND resource.type="consumer_quota" \
        AND resource.label.service="aiplatform.googleapis.com"
        """

        let usageSeries = try await fetchTimeSeries(
            accessToken: accessToken, projectId: projectId, filter: usageFilter, session: session)
        let limitSeries = try await fetchTimeSeries(
            accessToken: accessToken, projectId: projectId, filter: limitFilter, session: session)

        let usageByKey = aggregate(series: usageSeries)
        let limitByKey = aggregate(series: limitSeries)

        guard !usageByKey.isEmpty, !limitByKey.isEmpty else {
            throw VertexAIUsageError.noData
        }

        var maxPercent: Double?
        var matchedCount = 0
        for (key, limit) in limitByKey {
            guard limit > 0, let usage = usageByKey[key] else { continue }
            matchedCount += 1
            let percent = (usage / limit) * 100.0
            maxPercent = max(maxPercent ?? percent, percent)
        }

        guard let usedPercent = maxPercent, matchedCount > 0 else {
            throw VertexAIUsageError.noData
        }
        return usedPercent
    }

    private static func fetchTimeSeries(
        accessToken: String,
        projectId: String,
        filter: String,
        session: URLSession) async throws -> [MonitoringTimeSeries]
    {
        let now = Date()
        let start = now.addingTimeInterval(-usageWindowSeconds)
        let formatter = ISO8601DateFormatter()
        var pageToken: String?
        var allSeries: [MonitoringTimeSeries] = []

        repeat {
            guard var components = URLComponents(
                string: "\(monitoringEndpoint)/\(projectId)/timeSeries")
            else { throw VertexAIUsageError.invalidResponse }

            var queryItems = [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "interval.startTime", value: formatter.string(from: start)),
                URLQueryItem(name: "interval.endTime", value: formatter.string(from: now)),
                URLQueryItem(name: "aggregation.alignmentPeriod", value: "3600s"),
                URLQueryItem(name: "aggregation.perSeriesAligner", value: "ALIGN_MAX"),
                URLQueryItem(name: "view", value: "FULL"),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            guard let url = components.url else { throw VertexAIUsageError.invalidResponse }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let data: Data
            let http: HTTPURLResponse
            do {
                let (d, response) = try await session.data(for: request)
                guard let h = response as? HTTPURLResponse else { throw VertexAIUsageError.invalidResponse }
                data = d
                http = h
            } catch let e as VertexAIUsageError {
                throw e
            } catch {
                throw VertexAIUsageError.network(error.localizedDescription)
            }

            switch http.statusCode {
            case 401: throw VertexAIUsageError.unauthorized
            case 403: throw VertexAIUsageError.forbidden
            case 200: break
            default: throw VertexAIUsageError.server(http.statusCode)
            }

            let decoded: MonitoringTimeSeriesResponse
            do {
                decoded = try JSONDecoder().decode(MonitoringTimeSeriesResponse.self, from: data)
            } catch {
                throw VertexAIUsageError.invalidResponse
            }
            if let series = decoded.timeSeries {
                allSeries.append(contentsOf: series)
            }
            pageToken = decoded.nextPageToken?.isEmpty == false ? decoded.nextPageToken : nil
        } while pageToken != nil

        return allSeries
    }

    private static func aggregate(series: [MonitoringTimeSeries]) -> [QuotaKey: Double] {
        var buckets: [QuotaKey: Double] = [:]
        for entry in series {
            guard let key = quotaKey(from: entry),
                  let value = maxPointValue(from: entry.points)
            else { continue }
            buckets[key] = max(buckets[key] ?? 0, value)
        }
        return buckets
    }

    private static func quotaKey(from series: MonitoringTimeSeries) -> QuotaKey? {
        let metricLabels = series.metric.labels ?? [:]
        let resourceLabels = series.resource.labels ?? [:]
        let quotaMetric = metricLabels["quota_metric"] ?? resourceLabels["quota_id"]
        guard let quotaMetric, !quotaMetric.isEmpty else { return nil }
        let limitName = metricLabels["limit_name"] ?? ""
        let location = resourceLabels["location"] ?? "global"
        return QuotaKey(quotaMetric: quotaMetric, limitName: limitName, location: location)
    }

    private static func maxPointValue(from points: [MonitoringPoint]) -> Double? {
        points.compactMap(pointValue).max()
    }

    private static func pointValue(from point: MonitoringPoint) -> Double? {
        if let doubleValue = point.value.doubleValue { return doubleValue }
        if let int64Value = point.value.int64Value { return Double(int64Value) }
        return nil
    }
}
