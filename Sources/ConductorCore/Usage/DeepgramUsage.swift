import Foundation

/// Deepgram（语音转写/合成平台）用量取数。摘自 CodexBar `Deepgram` provider，自足、不依赖 cookie：
/// 用 `Token <apiKey>` 头调 Management API：先 `GET /v1/projects` 列项目，再对每个项目调
/// `GET /v1/projects/{id}/usage/breakdown`，汇总 requests / audio hours / billable hours /
/// agent hours / tokens / TTS chars。账号级（与具体 CLI 无关）。
///
/// 环境变量：`DEEPGRAM_API_KEY`（必需）、`DEEPGRAM_PROJECT_ID`（可选，省略则枚举全部项目并汇总）、
/// `DEEPGRAM_API_URL`（可选覆盖 base URL）。
///
/// 凭证来源：仅环境变量 token（CodexBar 的 `ProviderTokenResolver.deepgramResolution` 只走
/// `DeepgramSettingsReader.apiKey`/`.projectID` 的 `.environment`，无 cookie/浏览器路径），故优先 token。
///
/// 说明：Deepgram 的 usage/breakdown 接口只返回「用量计数」（请求数、时长、token 数等），
/// 不返回额度/上限/余额/$，无法算「已用/总额」百分比，也无周期窗口。
/// 权威来源 CodexBar 的 `DeepgramUsageSnapshot` 同样无 amount/balance/limit 字段，其
/// `toUsageSnapshot()` 亦 `providerCost: nil`（把计数塞进自有的 `deepgramUsage` 字段）。
/// conductor 富模型无 `deepgramUsage` 承载位，且无真实 $ 余额可映射，故 `providerCost = nil`；
/// 这里忠实保留：单个 `primary` 无配额窗（`usedPercent=0`、reset=now+30 天），项目标签放 `planName`。
public enum DeepgramUsageError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidCredentials
    case invalidProjectID
    case forbidden(String)
    case server(Int)
    case apiError(String)
    case parseFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: L("未找到 Deepgram 令牌，请设置环境变量 DEEPGRAM_API_KEY")
        case .invalidCredentials: L("Deepgram 令牌无效或已过期，请检查 API key")
        case .invalidProjectID: L("Deepgram 项目 ID 无效，或该 API key 下没有项目")
        case let .forbidden(m): L("Deepgram 拒绝访问：%@", m)
        case let .server(code): L("Deepgram 接口错误（%ld）", code)
        case let .apiError(m): L("Deepgram API 错误：%@", m)
        case let .parseFailed(m): L("Deepgram 用量接口解析失败：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum DeepgramUsageFetcher {
    private static let defaultBaseURL = URL(string: "https://api.deepgram.com/v1")!
    private static let timeoutSeconds: TimeInterval = 15

    /// 是否配置了 Deepgram 令牌（用于在工具面板里把 Deepgram 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        apiKey(env: env) != nil
    }

    // 与 CodexBar DeepgramSettingsReader 一致：DEEPGRAM_API_KEY，去引号去空白。
    static func apiKey(env: [String: String]) -> String? {
        clean(env["DEEPGRAM_API_KEY"])
    }

    static func projectID(env: [String: String]) -> String? {
        clean(env["DEEPGRAM_PROJECT_ID"])
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// `DEEPGRAM_API_URL` 覆盖：能解析为合法 URL 则用，否则回退默认 base URL。
    static func apiURL(env: [String: String]) -> URL {
        if let raw = clean(env["DEEPGRAM_API_URL"]), let url = URL(string: raw) {
            return url
        }
        return defaultBaseURL
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = apiKey(env: env) else { throw DeepgramUsageError.missingAPIKey }

        // 指定了项目 ID：只取该项目；否则枚举全部项目并汇总。
        let snapshots: [ProjectUsage]
        if let pid = projectID(env: env) {
            let usage = try await fetchUsage(
                project: Project(projectID: pid, name: nil),
                apiKey: apiKey, env: env, session: session)
            snapshots = [usage]
        } else {
            let projects = try await listProjects(apiKey: apiKey, env: env, session: session)
            guard !projects.isEmpty else { throw DeepgramUsageError.invalidProjectID }
            var acc: [ProjectUsage] = []
            acc.reserveCapacity(projects.count)
            for project in projects {
                acc.append(try await fetchUsage(
                    project: project, apiKey: apiKey, env: env, session: session))
            }
            snapshots = acc
        }

        let aggregated = try aggregate(snapshots)
        return makeSnapshot(aggregated)
    }

    // MARK: - 网络

    private static func listProjects(
        apiKey: String,
        env: [String: String],
        session: URLSession) async throws -> [Project]
    {
        let url = apiURL(env: env).appendingPathComponent("projects")
        let data = try await perform(url: url, apiKey: apiKey, session: session)
        do {
            return try JSONDecoder().decode(ProjectsResponse.self, from: data).projects
        } catch {
            throw DeepgramUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func fetchUsage(
        project: Project,
        apiKey: String,
        env: [String: String],
        session: URLSession) async throws -> ProjectUsage
    {
        let url = apiURL(env: env)
            .appendingPathComponent("projects")
            .appendingPathComponent(project.projectID)
            .appendingPathComponent("usage")
            .appendingPathComponent("breakdown")
        let data = try await perform(url: url, apiKey: apiKey, session: session)
        return try parseUsage(data: data, project: project)
    }

    private static func perform(
        url: URL,
        apiKey: String,
        session: URLSession) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw DeepgramUsageError.parseFailed("无 HTTP 响应") }
            data = d
            http = h
        } catch let e as DeepgramUsageError {
            throw e
        } catch {
            throw DeepgramUsageError.network(error.localizedDescription)
        }

        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401:
                throw DeepgramUsageError.invalidCredentials
            case 403:
                throw DeepgramUsageError.forbidden("API key 可能无权访问该项目或 Management API")
            case 400:
                throw DeepgramUsageError.apiError("请求无效（HTTP 400）")
            default:
                throw DeepgramUsageError.server(http.statusCode)
            }
        }
        return data
    }

    // MARK: - 解析

    private struct ProjectsResponse: Decodable {
        let projects: [Project]
    }

    private struct Project: Decodable {
        let projectID: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case name
        }
    }

    private struct UsageResponse: Decodable {
        let start: String?
        let end: String?
        let results: [UsageResult]
    }

    private struct UsageResult: Decodable {
        let hours: Double?
        let totalHours: Double?
        let agentHours: Double?
        let tokensIn: Int?
        let tokensOut: Int?
        let ttsCharacters: Int?
        let requests: Int?

        enum CodingKeys: String, CodingKey {
            case hours
            case totalHours = "total_hours"
            case agentHours = "agent_hours"
            case tokensIn = "tokens_in"
            case tokensOut = "tokens_out"
            case ttsCharacters = "tts_characters"
            case requests
        }
    }

    /// 单个项目的用量汇总（CodexBar DeepgramUsageSnapshot 的精简版）。
    private struct ProjectUsage {
        let projectID: String
        let projectName: String?
        let projectCount: Int
        let start: String?
        let end: String?
        let requests: Int
    }

    private static func parseUsage(data: Data, project: Project) throws -> ProjectUsage {
        let response: UsageResponse
        do {
            response = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw DeepgramUsageError.parseFailed(error.localizedDescription)
        }
        return ProjectUsage(
            projectID: project.projectID,
            projectName: project.name,
            projectCount: 1,
            start: response.start,
            end: response.end,
            requests: response.results.reduce(0) { $0 + ($1.requests ?? 0) })
    }

    /// 多项目汇总：单项目直接返回；多项目合并请求数、起止区间，并标记项目数。
    private static func aggregate(_ snapshots: [ProjectUsage]) throws -> ProjectUsage {
        guard let first = snapshots.first else { throw DeepgramUsageError.invalidProjectID }
        if snapshots.count == 1 { return first }
        return ProjectUsage(
            projectID: "all",
            projectName: nil,
            projectCount: snapshots.count,
            start: snapshots.compactMap(\.start).min(),
            end: snapshots.compactMap(\.end).max(),
            requests: snapshots.reduce(0) { $0 + $1.requests })
    }

    private static func makeSnapshot(_ usage: ProjectUsage) -> UsageSnapshot {
        // Deepgram usage/breakdown 无额度/上限/余额/$：保留单个无配额 primary 窗
        // （usedPercent=0、reset=now+30 天），项目标签放 planName。无真实 $ 余额可映射，
        // 故 providerCost = nil（与权威源 CodexBar 的 toUsageSnapshot 一致）。
        let primary = RateWindow(
            title: L("会话"),
            usedPercent: 0,
            resetsAt: Date().addingTimeInterval(30 * 86400))
        return UsageSnapshot(
            primary: primary,
            providerCost: nil,
            planName: planLabel(usage))
    }

    /// 套餐/账号标签：多项目用「N projects」，单项目优先项目名，否则项目 ID。
    private static func planLabel(_ usage: ProjectUsage) -> String? {
        if usage.projectCount > 1 {
            return "\(usage.projectCount) projects"
        }
        if let name = usage.projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "Project: \(name)"
        }
        return "Project: \(usage.projectID)"
    }
}
