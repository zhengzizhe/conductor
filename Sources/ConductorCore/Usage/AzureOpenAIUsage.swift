import Foundation

/// Azure OpenAI 用量取数。忠实摘自 CodexBar `AzureOpenAI` provider（token/env 路径，无 cookie）：
/// 读环境变量 `AZURE_OPENAI_API_KEY` / `AZURE_OPENAI_ENDPOINT` / `AZURE_OPENAI_DEPLOYMENT_NAME`
/// （可选 `AZURE_OPENAI_API_VERSION`，默认 `2024-10-21`），用 `api-key` 头对部署发一次
/// 极小的 `chat/completions` 校验请求（`max_tokens:1` 或 v1 的 `max_completion_tokens:1`）来探活。
///
/// 注意：CodexBar 这个 provider 不暴露任何配额/额度历史——校验探针只能确认部署可用并回读 `model` 字段，
/// 没有「已用百分比/重置周期」。因此本快照按「无周期」处理：session 窗 usedPercent=0、resetAt=now+30 天、
/// weekly=nil。环境变量与 CodexBar `AzureOpenAISettingsReader` 完全一致；端点路径拼接与
/// `AzureOpenAIUsageFetcher.chatCompletionsURL` 完全一致（含 v1 与经典 api-version 两种形态）。
public enum AzureOpenAIUsageError: LocalizedError, Sendable {
    case missingAPIKey
    case missingEndpoint
    case missingDeploymentName
    case invalidEndpoint
    case invalidURL
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: L("未配置 Azure OpenAI 密钥，请设置环境变量 AZURE_OPENAI_API_KEY")
        case .missingEndpoint: L("未配置 Azure OpenAI 端点，请设置环境变量 AZURE_OPENAI_ENDPOINT")
        case .missingDeploymentName: L("未配置 Azure OpenAI 部署，请设置环境变量 AZURE_OPENAI_DEPLOYMENT_NAME")
        case .invalidEndpoint: L("Azure OpenAI 端点无效")
        case .invalidURL: L("Azure OpenAI 校验地址无效")
        case let .server(code): L("Azure OpenAI 接口错误（%ld）", code)
        case .invalidResponse: L("Azure OpenAI 用量接口返回异常")
        case let .network(msg): L("网络错误：%@", msg)
        }
    }
}

public enum AzureOpenAIUsageFetcher {
    static let apiKeyEnvironmentKey = "AZURE_OPENAI_API_KEY"
    static let endpointEnvironmentKey = "AZURE_OPENAI_ENDPOINT"
    static let deploymentNameEnvironmentKey = "AZURE_OPENAI_DEPLOYMENT_NAME"
    static let apiVersionEnvironmentKey = "AZURE_OPENAI_API_VERSION"
    static let defaultAPIVersion = "2024-10-21"
    private static let timeoutSeconds: TimeInterval = 20

    /// 是否配置了 Azure OpenAI 密钥（用于在工具面板里把该 provider 视作「可用」）。
    /// 与 CodexBar `ProviderTokenResolver.azureOpenAIToken` 一致：只读 env 里的 API key。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        apiKey(env: env) != nil
    }

    // MARK: - 凭证（与 CodexBar AzureOpenAISettingsReader 对齐）

    static func apiKey(env: [String: String]) -> String? {
        cleaned(env[apiKeyEnvironmentKey])
    }

    static func endpoint(env: [String: String]) -> URL? {
        guard let raw = cleaned(env[endpointEnvironmentKey]) else { return nil }
        return endpointURL(from: raw)
    }

    static func deploymentName(env: [String: String]) -> String? {
        cleaned(env[deploymentNameEnvironmentKey])
    }

    static func apiVersion(env: [String: String]) -> String {
        cleaned(env[apiVersionEnvironmentKey]) ?? defaultAPIVersion
    }

    static func endpointURL(from rawEndpoint: String) -> URL? {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return nil
        }
        return url
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

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        guard let apiKey = apiKey(env: env) else { throw AzureOpenAIUsageError.missingAPIKey }
        guard let endpoint = endpoint(env: env) else { throw AzureOpenAIUsageError.missingEndpoint }
        guard let deploymentName = deploymentName(env: env) else { throw AzureOpenAIUsageError.missingDeploymentName }
        guard endpoint.host?.isEmpty == false else { throw AzureOpenAIUsageError.invalidEndpoint }

        let rawVersion = apiVersion(env: env).trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAPIVersion = rawVersion.isEmpty ? defaultAPIVersion : rawVersion

        let url = try chatCompletionsURL(
            endpoint: endpoint,
            deploymentName: deploymentName,
            apiVersion: effectiveAPIVersion)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try validationRequestBody(
            deploymentName: deploymentName,
            apiVersion: effectiveAPIVersion)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw AzureOpenAIUsageError.invalidResponse }
            data = d
            http = h
        } catch let error as AzureOpenAIUsageError {
            throw error
        } catch {
            throw AzureOpenAIUsageError.network(error.localizedDescription)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw AzureOpenAIUsageError.server(http.statusCode)
        }

        // 探针只确认部署可用（回读 model 字段，但 CodexBar 也只是把它当详情，不影响配额）。
        // Azure OpenAI 不暴露用量历史 → 无周期：session usedPercent=0、resetAt=now+30 天、weekly=nil。
        _ = data
        let window = CodexUsageSnapshot.Window(
            usedPercent: 0,
            resetAt: Date().addingTimeInterval(30 * 24 * 3600),
            windowSeconds: 30 * 24 * 3600)
        return CodexUsageSnapshot(planType: nil, session: window, weekly: nil)
    }

    // MARK: - 端点路径（忠实摘自 CodexBar AzureOpenAIUsageFetcher）

    static func chatCompletionsURL(
        endpoint: URL,
        deploymentName: String,
        apiVersion: String) throws -> URL
    {
        if usesV1API(apiVersion) {
            let base = apiRoot(endpoint: endpoint, pathComponents: ["openai", "v1"])
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
            guard let url = URLComponents(url: base, resolvingAgainstBaseURL: false)?.url else {
                throw AzureOpenAIUsageError.invalidURL
            }
            return url
        }

        let base = apiRoot(endpoint: endpoint, pathComponents: ["openai"])
            .appendingPathComponent("deployments")
            .appendingPathComponent(deploymentName)
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AzureOpenAIUsageError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        guard let url = components.url else { throw AzureOpenAIUsageError.invalidURL }
        return url
    }

    private static func apiRoot(endpoint: URL, pathComponents expectedComponents: [String]) -> URL {
        let existingComponents = endpoint.pathComponents
            .filter { $0 != "/" }
            .map { $0.lowercased() }
        let expectedComponents = expectedComponents.map { $0.lowercased() }
        let sharedCount = stride(
            from: min(existingComponents.count, expectedComponents.count),
            through: 0,
            by: -1)
            .first { count in
                count == 0 || Array(existingComponents.suffix(count)) == Array(expectedComponents.prefix(count))
            } ?? 0
        return expectedComponents.dropFirst(sharedCount).reduce(endpoint) { url, component in
            url.appendingPathComponent(component)
        }
    }

    private static func validationRequestBody(
        deploymentName: String,
        apiVersion: String) throws -> Data
    {
        var payload: [String: Any] = [
            "messages": [
                ["role": "user", "content": "ping"],
            ],
        ]
        if usesV1API(apiVersion) {
            payload["model"] = deploymentName
            payload["max_completion_tokens"] = 1
        } else {
            payload["max_tokens"] = 1
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private static func usesV1API(_ apiVersion: String) -> Bool {
        apiVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "v1"
    }
}
