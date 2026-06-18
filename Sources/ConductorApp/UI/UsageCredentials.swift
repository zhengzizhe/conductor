import ConductorCore
import Foundation

/// 账号用量凭证桥接：把应用内填写的 provider 配置注入进程环境变量，并解析 provider 的「是否显示」。
///
/// 背景：各 provider 的 fetcher 默认读 `ProcessInfo.processInfo.environment`，而 Finder 启动的 GUI
/// **不继承** 用户 shell 里 export 的变量（如 `Z_AI_API_KEY`）。CodexBar 的做法是让用户在应用内填 key、
/// 再注入抓取进程的 env。这里照搬并扩展：把 config.yaml 里的 API key、Cookie、Base URL、项目/组织
/// 字段翻译成各 fetcher 已经支持的环境变量，避免 UI 设置只是“看起来能填”。
enum UsageCredentials {
    private static var activeManagedEnvNames: Set<String> = []
    private static var originalEnvValues: [String: String] = [:]
    private static var originallyMissingEnvNames: Set<String> = []
    private static let browserCredentialProviderIDs: Set<String> = [
        "abacus",
        "alibabatokenplan",
        "augment",
        "commandcode",
        "copilot",
        "cursor",
        "devin",
        "factory",
        "grok",
        "manus",
        "mimo",
        "mistral",
        "ollama",
        "opencode",
        "opencodego",
        "perplexity",
        "t3chat",
        "windsurf",
    ]

    /// provider id → 主环境变量名（仅 API-key / token 型 provider）。
    /// cookie / OAuth / 本地登录文件型不在此（它们另有检测路径，不靠 env key）。
    static let envVar: [String: String] = [
        "glm": "Z_AI_API_KEY",
        "minimax": "MINIMAX_API_KEY",
        "qwen": "DASHSCOPE_API_KEY",
        "openrouter": "OPENROUTER_API_KEY",
        "deepseek": "DEEPSEEK_API_KEY",
        "kimi": "KIMI_CODE_API_KEY",
        "moonshot": "MOONSHOT_API_KEY",
        "groq": "GROQ_API_KEY",
        "openai": "OPENAI_ADMIN_KEY",
        "amp": "AMP_API_KEY",
        "azureopenai": "AZURE_OPENAI_API_KEY",
        "devin": "DEVIN_BEARER_TOKEN",
        "manus": "MANUS_SESSION_TOKEN",
        "kilo": "KILO_API_KEY",
        "kimik2": "KIMI_K2_API_KEY",
        "codebuff": "CODEBUFF_API_KEY",
        "synthetic": "SYNTHETIC_API_KEY",
        "elevenlabs": "ELEVENLABS_API_KEY",
        "doubao": "ARK_API_KEY",
        "crof": "CROF_API_KEY",
        "venice": "VENICE_API_KEY",
        "commandcode": "COMMANDCODE_TOKEN",
        "stepfun": "STEPFUN_TOKEN",
        "llmproxy": "LLM_PROXY_API_KEY",
        "deepgram": "DEEPGRAM_API_KEY",
        "warp": "WARP_API_KEY",
        "perplexity": "PERPLEXITY_SESSION_TOKEN",
        "alibabatokenplan": "ALIBABA_TOKEN_PLAN_COOKIE",
    ]

    private static let apiKeyAliases: [String: [String]] = [
        "glm": ["ZAI_API_KEY", "GLM_API_KEY"],
        "minimax": ["MINIMAX_CODING_API_KEY"],
        "qwen": ["ALIBABA_QWEN_API_KEY", "ALIBABA_CODING_PLAN_API_KEY"],
        "deepseek": ["DEEPSEEK_KEY"],
        "moonshot": ["MOONSHOT_KEY"],
        "openai": ["OPENAI_API_KEY"],
        "devin": ["DEVIN_AUTHORIZATION"],
        "manus": ["MANUS_SESSION_ID", "MANUS_COOKIE"],
        "kimik2": ["KIMI_API_KEY", "KIMI_KEY"],
        "elevenlabs": ["XI_API_KEY"],
        "doubao": ["VOLCENGINE_API_KEY", "DOUBAO_API_KEY"],
        "crof": ["CROFAI_API_KEY"],
        "venice": ["VENICE_KEY"],
        "commandcode": ["COMMANDCODE_SESSION_TOKEN", "COMMANDCODE_COOKIE"],
        "warp": ["WARP_TOKEN"],
    ]

    private static let baseURLEnvVar: [String: String] = [
        "glm": "Z_AI_API_HOST",
        "openrouter": "OPENROUTER_API_URL",
        "kimi": "KIMI_CODE_BASE_URL",
        "groq": "GROQ_API_URL",
        "codebuff": "CODEBUFF_API_URL",
        "azureopenai": "AZURE_OPENAI_ENDPOINT",
        "llmproxy": "LLM_PROXY_BASE_URL",
        "deepgram": "DEEPGRAM_API_URL",
        "elevenlabs": "ELEVENLABS_API_URL",
        "bedrock": "CODEXBAR_BEDROCK_API_URL",
    ]

    private static let projectEnvVars: [String: [String]] = [
        "azureopenai": ["AZURE_OPENAI_DEPLOYMENT_NAME"],
        "deepgram": ["DEEPGRAM_PROJECT_ID"],
        "vertexai": ["GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT"],
        "opencode": ["CODEXBAR_OPENCODE_WORKSPACE_ID"],
        "opencodego": ["CODEXBAR_OPENCODEGO_WORKSPACE_ID"],
        "openai": ["OPENAI_PROJECT_ID"],
    ]

    private static let organizationEnvVars: [String: [String]] = [
        "devin": ["DEVIN_ORGANIZATION", "DEVIN_ORG"],
        "openai": ["OPENAI_ORG_ID", "OPENAI_ORGANIZATION"],
    ]

    private static let cookieHeaderEnvVars: [String: [String]] = [
        "alibabatokenplan": ["ALIBABA_TOKEN_PLAN_COOKIE"],
        "commandcode": ["COMMANDCODE_SESSION_TOKEN", "COMMANDCODE_COOKIE", "COMMANDCODE_TOKEN"],
        "perplexity": ["PERPLEXITY_COOKIE"],
        "manus": ["MANUS_COOKIE"],
    ]

    private static let extraEnvVars: [String: [String: [String]]] = [
        "azureopenai": [
            "apiVersion": ["AZURE_OPENAI_API_VERSION"],
        ],
        "bedrock": [
            "awsAccessKeyID": ["AWS_ACCESS_KEY_ID"],
            "awsSecretAccessKey": ["AWS_SECRET_ACCESS_KEY"],
            "awsSessionToken": ["AWS_SESSION_TOKEN"],
            "awsRegion": ["AWS_REGION", "AWS_DEFAULT_REGION"],
            "awsBudget": ["CODEXBAR_BEDROCK_BUDGET"],
        ],
        "glm": [
            "quotaURL": ["Z_AI_QUOTA_URL"],
        ],
        "moonshot": [
            "region": ["MOONSHOT_REGION"],
        ],
        "openrouter": [
            "httpReferer": ["OPENROUTER_HTTP_REFERER"],
            "clientTitle": ["OPENROUTER_X_TITLE"],
        ],
        "stepfun": [
            "username": ["STEPFUN_USERNAME"],
            "password": ["STEPFUN_PASSWORD"],
        ],
        "antigravity": [
            "oauthCredentialsJSON": ["ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"],
            "oauthClientID": ["ANTIGRAVITY_OAUTH_CLIENT_ID"],
            "oauthClientSecret": ["ANTIGRAVITY_OAUTH_CLIENT_SECRET"],
        ],
    ]

    /// 该 provider 是否支持「应用内填 key」（即有可注入的环境变量）。
    static func acceptsAPIKey(_ id: String) -> Bool { self.envVar[id] != nil }

    /// 把应用内配置写进进程环境，使 fetcher 能取到。幂等，可重复调用。
    static func apply(_ config: AppConfig) {
        var nextManagedEnvNames: Set<String> = []
        for (id, providerConfig) in config.usage.providers {
            guard providerConfig.enabled ?? true else { continue }
            applyProviderConfig(id: id, config: providerConfig, managedEnvNames: &nextManagedEnvNames)
        }

        if config.usage.providers["claude"]?.flags["avoidKeychainPrompts"] == true {
            apply("1", to: ["CONDUCTOR_CLAUDE_AVOID_KEYCHAIN"], managedEnvNames: &nextManagedEnvNames)
        }
        restoreInactiveManagedEnvNames(keeping: nextManagedEnvNames)
        activeManagedEnvNames = nextManagedEnvNames
    }

    /// provider 是否应在用量区显示：
    /// 默认**全部显示**（像 CodexBar 那样把各渠道都列出来）；只有用户在设置里显式关掉才隐藏。
    /// 配置好凭证的显示用量，没配的显示「未配置」。
    static func isVisible(_ entry: UsageProviderEntry, config: AppConfig) -> Bool {
        config.usage.providers[entry.id]?.enabled ?? true
    }

    /// Opening a usage drawer should not touch browser cookie stores, because Chromium
    /// cookie decryption can raise the system "Chrome Safe Storage" Keychain prompt.
    static func shouldDeferBrowserCredentialProbe(
        _ entry: UsageProviderEntry,
        config: AppConfig,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let id = entry.id
        guard browserCredentialProviderIDs.contains(id) else { return false }
        guard shouldReadBrowserCredentials(providerID: id, config: config, env: env) else { return false }
        return !hasManualCredential(providerID: id, config: config, env: env)
    }

    static func isConfiguredWithoutBrowserPrompt(
        _ entry: UsageProviderEntry,
        config: AppConfig,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !shouldDeferBrowserCredentialProbe(entry, config: config, env: env) else {
            return false
        }
        return entry.isConfigured()
    }

    private static func applyProviderConfig(
        id: String,
        config: UsageProviderConfig,
        managedEnvNames: inout Set<String>
    ) {
        if let value = normalized(config.apiKey), let primary = envVar[id] {
            apply(value, to: [primary] + (apiKeyAliases[id] ?? []), managedEnvNames: &managedEnvNames)
        }

        if let value = normalized(config.cookieHeader) {
            apply(
                value,
                to: cookieHeaderEnvVars[id] ?? conductorCookieEnvNames(id),
                managedEnvNames: &managedEnvNames)
        }

        if let value = normalized(config.baseURL), let envName = baseURLEnvVar[id] {
            apply(value, to: [envName], managedEnvNames: &managedEnvNames)
        }

        if let value = normalized(config.projectID), let envNames = projectEnvVars[id] {
            apply(value, to: envNames, managedEnvNames: &managedEnvNames)
        }

        if let value = normalized(config.organizationID), let envNames = organizationEnvVars[id] {
            apply(value, to: envNames, managedEnvNames: &managedEnvNames)
        }

        if let value = normalized(config.sourceMode) {
            apply(value, to: conductorSourceEnvNames(id), managedEnvNames: &managedEnvNames)
        }
        if let value = normalized(config.cookieSource) {
            apply(value, to: conductorCookieSourceEnvNames(id), managedEnvNames: &managedEnvNames)
        }

        for (key, value) in config.extra {
            guard let value = normalized(value) else { continue }
            apply(value, to: extraEnvNames(providerID: id, key: key), managedEnvNames: &managedEnvNames)
        }
    }

    private static func apply(_ value: String, to names: [String], managedEnvNames: inout Set<String>) {
        for name in names where !name.isEmpty {
            recordOriginalEnvValue(for: name)
            setenv(name, value, 1)
            managedEnvNames.insert(name)
        }
    }

    private static func restoreInactiveManagedEnvNames(keeping nextManagedEnvNames: Set<String>) {
        let inactive = activeManagedEnvNames.subtracting(nextManagedEnvNames)
        for name in inactive {
            if let original = originalEnvValues[name] {
                setenv(name, original, 1)
            } else {
                unsetenv(name)
            }
        }
    }

    private static func recordOriginalEnvValue(for name: String) {
        guard originalEnvValues[name] == nil, !originallyMissingEnvNames.contains(name) else {
            return
        }
        if let existing = getenv(name) {
            originalEnvValues[name] = String(cString: existing)
        } else {
            originallyMissingEnvNames.insert(name)
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func hasManualCredential(
        providerID id: String,
        config: AppConfig,
        env: [String: String]
    ) -> Bool {
        let providerConfig = config.usage.providers[id]
        if normalized(providerConfig?.apiKey) != nil { return true }
        if normalized(providerConfig?.cookieHeader) != nil { return true }

        var names: [String] = []
        if let primary = envVar[id] { names.append(primary) }
        names += apiKeyAliases[id] ?? []
        names += cookieHeaderEnvVars[id] ?? conductorCookieEnvNames(id)

        return names.contains { envValue($0, env: env) != nil }
    }

    private static func shouldReadBrowserCredentials(
        providerID id: String,
        config: AppConfig,
        env: [String: String]
    ) -> Bool {
        let providerConfig = config.usage.providers[id]
        if let cookieSource = normalized(providerConfig?.cookieSource)
            ?? envValue("CONDUCTOR_USAGE_\(envSafe(id))_COOKIE_SOURCE", env: env)
        {
            switch cookieSource.lowercased() {
            case "manual", "off":
                return false
            default:
                return true
            }
        }

        let sourceMode = normalized(providerConfig?.sourceMode)
            ?? envValue("CONDUCTOR_USAGE_\(envSafe(id))_SOURCE", env: env)
        switch sourceMode?.lowercased() {
        case "api", "cli", "file", "keychain", "manual", "oauth", "off", "token":
            return false
        case "browser":
            return true
        default:
            return true
        }
    }

    private static func envValue(_ name: String, env: [String: String]) -> String? {
        if let value = normalized(env[name]) { return value }
        guard let raw = getenv(name) else { return nil }
        return normalized(String(cString: raw))
    }

    private static func conductorCookieEnvNames(_ id: String) -> [String] {
        ["CONDUCTOR_USAGE_\(envSafe(id))_COOKIE"]
    }

    private static func conductorSourceEnvNames(_ id: String) -> [String] {
        ["CONDUCTOR_USAGE_\(envSafe(id))_SOURCE"]
    }

    private static func conductorCookieSourceEnvNames(_ id: String) -> [String] {
        ["CONDUCTOR_USAGE_\(envSafe(id))_COOKIE_SOURCE"]
    }

    private static func extraEnvNames(providerID: String, key: String) -> [String] {
        extraEnvVars[providerID]?[key] ?? ["CONDUCTOR_USAGE_\(envSafe(providerID))_\(envSafe(key))"]
    }

    private static func envSafe(_ raw: String) -> String {
        raw.uppercased().map { ch in
            ch.isLetter || ch.isNumber ? ch : "_"
        }.reduce(into: "") { $0.append($1) }
    }
}
