import ConductorCore
import Foundation

/// 账号级用量 provider —— 与 CLI 二进制检测解耦。只要本机存在该 provider 的凭证
/// （登录文件 / Keychain / 环境变量 API key），就在「账号用量」区展示其额度，
/// 不要求对应的命令行工具已安装。
struct UsageProviderEntry: Identifiable, Sendable {
    let id: String
    let name: String
    /// Resources/Logos 里的资源名（缺失则用 fallbackSystemImage）。
    let logo: String
    let fallbackSystemImage: String
    /// 凭证是否存在（便宜的本地检查，不发网络、不弹钥匙串授权框）。
    let isConfigured: @Sendable () -> Bool
    /// 拉取该 provider 的富用量快照（会话/周/额度等）。
    let fetch: @Sendable () async throws -> UsageSnapshot

    var logoName: String { logo.isEmpty ? id : logo }
}

enum UsageProviderCatalog {
    static let all: [UsageProviderEntry] = [
        UsageProviderEntry(
            id: "codex", name: "Codex", logo: "codex",
            fallbackSystemImage: "chevron.left.forwardslash.chevron.right",
            isConfigured: { CodexUsageFetcher.hasCredentials() },
            fetch: { UsageSnapshot(codexSnapshot: try await CodexUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "claude", name: "Claude", logo: "claude",
            fallbackSystemImage: "sparkles",
            isConfigured: { ClaudeUsageFetcher.hasCredentials() },
            fetch: { try await ClaudeUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "gemini", name: "Gemini", logo: "gemini",
            fallbackSystemImage: "diamond",
            isConfigured: { GeminiUsageFetcher.hasCredentials() },
            fetch: { UsageSnapshot(codexSnapshot: try await GeminiUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "glm", name: "GLM (Z.ai)", logo: "glm",
            fallbackSystemImage: "g.square",
            isConfigured: { GLMUsageFetcher.hasToken() },
            fetch: { UsageSnapshot(codexSnapshot: try await GLMUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "minimax", name: "MiniMax", logo: "minimax",
            fallbackSystemImage: "m.square",
            isConfigured: { MiniMaxUsageFetcher.hasToken() },
            fetch: { try await MiniMaxUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "qwen", name: "Qwen (通义)", logo: "qwen",
            fallbackSystemImage: "q.square",
            isConfigured: { QwenUsageFetcher.hasToken() },
            fetch: { UsageSnapshot(codexSnapshot: try await QwenUsageFetcher.fetch()) }),
        // Cursor 是 cookie 类（从浏览器读 cursor.com 登录态）。isConfigured 会触发一次浏览器 cookie 读取。
        UsageProviderEntry(
            id: "cursor", name: "Cursor", logo: "cursor",
            fallbackSystemImage: "cursorarrow.rays",
            isConfigured: { CursorUsageFetcher.hasSession() },
            fetch: { try await CursorUsageFetcher.fetch() }),
        // —— 第一批转写（cookie/token 混合）——
        UsageProviderEntry(
            id: "grok", name: "Grok", logo: "grok", fallbackSystemImage: "bolt.fill",
            isConfigured: { GrokUsageFetcher.hasSession() }, fetch: { UsageSnapshot(codexSnapshot: try await GrokUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "copilot", name: "GitHub Copilot", logo: "copilot", fallbackSystemImage: "command",
            isConfigured: { CopilotUsageFetcher.hasSession() }, fetch: { UsageSnapshot(codexSnapshot: try await CopilotUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "openrouter", name: "OpenRouter", logo: "openrouter", fallbackSystemImage: "arrow.triangle.swap",
            isConfigured: { OpenRouterUsageFetcher.hasToken() }, fetch: { try await OpenRouterUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "deepseek", name: "DeepSeek", logo: "deepseek", fallbackSystemImage: "water.waves",
            isConfigured: { DeepSeekUsageFetcher.hasToken() }, fetch: { try await DeepSeekUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "kimi", name: "Kimi", logo: "kimi", fallbackSystemImage: "k.square",
            isConfigured: { KimiUsageFetcher.hasToken() }, fetch: { try await KimiUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "mistral", name: "Mistral", logo: "mistral", fallbackSystemImage: "wind",
            isConfigured: { MistralUsageFetcher.hasSession() }, fetch: { try await MistralUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "moonshot", name: "Moonshot", logo: "moonshot", fallbackSystemImage: "moon.stars",
            isConfigured: { MoonshotUsageFetcher.hasToken() }, fetch: { try await MoonshotUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "groq", name: "Groq", logo: "groq", fallbackSystemImage: "cpu",
            isConfigured: { GroqUsageFetcher.hasToken() }, fetch: { UsageSnapshot(codexSnapshot: try await GroqUsageFetcher.fetch()) }),
        // —— 第二批转写 ——
        UsageProviderEntry(
            id: "opencode", name: "opencode", logo: "opencode", fallbackSystemImage: "curlybraces",
            isConfigured: { OpenCodeUsageFetcher.hasSession() }, fetch: { try await OpenCodeUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "ollama", name: "Ollama", logo: "ollama", fallbackSystemImage: "shippingbox",
            isConfigured: { OllamaUsageFetcher.hasSession() }, fetch: { UsageSnapshot(codexSnapshot: try await OllamaUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "openai", name: "OpenAI", logo: "openai", fallbackSystemImage: "brain",
            isConfigured: { OpenAIUsageFetcher.hasToken() }, fetch: { try await OpenAIUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "perplexity", name: "Perplexity", logo: "perplexity", fallbackSystemImage: "magnifyingglass",
            isConfigured: { PerplexityUsageFetcher.hasSession() }, fetch: { try await PerplexityUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "warp", name: "Warp", logo: "warp", fallbackSystemImage: "terminal",
            isConfigured: { WarpUsageFetcher.hasToken() }, fetch: { UsageSnapshot(codexSnapshot: try await WarpUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "augment", name: "Augment", logo: "augment", fallbackSystemImage: "puzzlepiece.extension",
            isConfigured: { AugmentUsageFetcher.hasSession() }, fetch: { UsageSnapshot(codexSnapshot: try await AugmentUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "amp", name: "Amp", logo: "amp", fallbackSystemImage: "bolt.horizontal.circle",
            isConfigured: { AmpUsageFetcher.hasToken() }, fetch: { UsageSnapshot(codexSnapshot: try await AmpUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "antigravity", name: "Antigravity", logo: "antigravity", fallbackSystemImage: "arrow.up",
            isConfigured: { AntigravityUsageFetcher.hasToken() }, fetch: { try await AntigravityUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "vertexai", name: "Vertex AI", logo: "vertexai", fallbackSystemImage: "triangle",
            isConfigured: { VertexAIUsageFetcher.hasCredentials() }, fetch: { UsageSnapshot(codexSnapshot: try await VertexAIUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "windsurf", name: "Windsurf", logo: "windsurf", fallbackSystemImage: "wind.snow",
            isConfigured: { WindsurfUsageFetcher.hasCredentials() || WindsurfUsageFetcher.hasSession() },
            fetch: { UsageSnapshot(codexSnapshot: try await WindsurfUsageFetcher.fetch()) }),
        // —— 第三批转写 ——
        UsageProviderEntry(
            id: "azureopenai", name: "Azure OpenAI", logo: "azureopenai", fallbackSystemImage: "a.square",
            isConfigured: { AzureOpenAIUsageFetcher.hasToken() }, fetch: { UsageSnapshot(codexSnapshot: try await AzureOpenAIUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "factory", name: "Factory", logo: "factory", fallbackSystemImage: "gearshape.2",
            isConfigured: { FactoryUsageFetcher.hasSession() }, fetch: { try await FactoryUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "devin", name: "Devin", logo: "devin", fallbackSystemImage: "ant",
            isConfigured: { DevinUsageFetcher.hasToken() || DevinUsageFetcher.hasSession() },
            fetch: { UsageSnapshot(codexSnapshot: try await DevinUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "manus", name: "Manus", logo: "manus", fallbackSystemImage: "hand.raised",
            isConfigured: { ManusUsageFetcher.hasToken() || ManusUsageFetcher.hasSession() },
            fetch: { try await ManusUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "kilo", name: "Kilo Code", logo: "kilo", fallbackSystemImage: "k.circle",
            isConfigured: { KiloUsageFetcher.hasToken() }, fetch: { try await KiloUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "kiro", name: "Kiro", logo: "kiro", fallbackSystemImage: "k.square.fill",
            isConfigured: { KiroUsageFetcher.hasCredentials() }, fetch: { try await KiroUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "jetbrains", name: "JetBrains AI", logo: "jetbrains", fallbackSystemImage: "j.square",
            isConfigured: { JetBrainsUsageFetcher.hasCredentials() }, fetch: { UsageSnapshot(codexSnapshot: try await JetBrainsUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "kimik2", name: "Kimi K2", logo: "kimik2", fallbackSystemImage: "k.circle.fill",
            isConfigured: { KimiK2UsageFetcher.hasToken() }, fetch: { try await KimiK2UsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "t3chat", name: "T3 Chat", logo: "t3chat", fallbackSystemImage: "t.square",
            isConfigured: { T3ChatUsageFetcher.hasSession() }, fetch: { UsageSnapshot(codexSnapshot: try await T3ChatUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "codebuff", name: "Codebuff", logo: "codebuff", fallbackSystemImage: "hammer",
            isConfigured: { CodebuffUsageFetcher.hasToken() }, fetch: { try await CodebuffUsageFetcher.fetch() }),
        // —— 第四批转写（收尾）——
        UsageProviderEntry(
            id: "opencodego", name: "opencode (Go)", logo: "opencodego", fallbackSystemImage: "chevron.left.forwardslash.chevron.right",
            isConfigured: { OpenCodeGoUsageFetcher.hasSession() }, fetch: { try await OpenCodeGoUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "alibabatokenplan", name: "通义 Token Plan", logo: "alibabatokenplan", fallbackSystemImage: "a.circle",
            isConfigured: { AlibabaTokenPlanUsageFetcher.hasToken() || AlibabaTokenPlanUsageFetcher.hasSession() },
            fetch: { UsageSnapshot(codexSnapshot: try await AlibabaTokenPlanUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "synthetic", name: "Synthetic", logo: "synthetic", fallbackSystemImage: "s.circle",
            isConfigured: { SyntheticUsageFetcher.hasToken() }, fetch: { try await SyntheticUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "elevenlabs", name: "ElevenLabs", logo: "elevenlabs", fallbackSystemImage: "waveform",
            isConfigured: { ElevenLabsUsageFetcher.hasToken() }, fetch: { try await ElevenLabsUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "mimo", name: "MiMo", logo: "mimo", fallbackSystemImage: "m.circle",
            isConfigured: { MiMoUsageFetcher.hasSession() }, fetch: { UsageSnapshot(codexSnapshot: try await MiMoUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "doubao", name: "Doubao", logo: "doubao", fallbackSystemImage: "d.circle",
            isConfigured: { DoubaoUsageFetcher.hasToken() }, fetch: { UsageSnapshot(codexSnapshot: try await DoubaoUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "abacus", name: "Abacus", logo: "abacus", fallbackSystemImage: "function",
            isConfigured: { AbacusUsageFetcher.hasSession() }, fetch: { UsageSnapshot(codexSnapshot: try await AbacusUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "crof", name: "Crof", logo: "crof", fallbackSystemImage: "c.circle",
            isConfigured: { CrofUsageFetcher.hasToken() }, fetch: { try await CrofUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "venice", name: "Venice", logo: "venice", fallbackSystemImage: "v.circle",
            isConfigured: { VeniceUsageFetcher.hasToken() }, fetch: { try await VeniceUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "commandcode", name: "CommandCode", logo: "commandcode", fallbackSystemImage: "command.circle",
            isConfigured: { CommandCodeUsageFetcher.hasToken() || CommandCodeUsageFetcher.hasSession() },
            fetch: { try await CommandCodeUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "stepfun", name: "StepFun", logo: "stepfun", fallbackSystemImage: "s.square",
            isConfigured: { StepFunUsageFetcher.hasToken() }, fetch: { UsageSnapshot(codexSnapshot: try await StepFunUsageFetcher.fetch()) }),
        UsageProviderEntry(
            id: "bedrock", name: "AWS Bedrock", logo: "bedrock", fallbackSystemImage: "cloud",
            isConfigured: { BedrockUsageFetcher.hasCredentials() }, fetch: { try await BedrockUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "llmproxy", name: "LLMProxy", logo: "llmproxy", fallbackSystemImage: "network",
            isConfigured: { LLMProxyUsageFetcher.hasToken() }, fetch: { try await LLMProxyUsageFetcher.fetch() }),
        UsageProviderEntry(
            id: "deepgram", name: "Deepgram", logo: "deepgram", fallbackSystemImage: "waveform.circle",
            isConfigured: { DeepgramUsageFetcher.hasToken() }, fetch: { try await DeepgramUsageFetcher.fetch() }),
    ]

    /// 本机已配置凭证的 provider（在后台调用：会读文件/Keychain 存在性）。
    static func configured() -> [UsageProviderEntry] {
        all.filter { $0.isConfigured() }
    }
}
