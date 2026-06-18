import Foundation

/// ElevenLabs（语音合成订阅）用量取数。摘自 CodexBar `ElevenLabs` provider，自足、不依赖 cookie：
/// 用 `xi-api-key` 头调 `https://api.elevenlabs.io/v1/user/subscription`，
/// 解析字符额度（character_count / character_limit）。账号级（与具体 CLI 无关）。
///
/// 环境变量：`ELEVENLABS_API_KEY` 或 `XI_API_KEY`（必需）、`ELEVENLABS_API_URL`（可选覆盖，须 HTTPS 或裸主机名）。
///
/// 凭证来源：仅环境变量 token（CodexBar 的 `ProviderTokenResolver.elevenLabsToken` 只走 `.environment`，无 cookie 路径），故优先 token。
public enum ElevenLabsUsageError: LocalizedError, Sendable {
    case missingToken
    case unauthorized
    case server(Int)
    case invalidResponse
    case invalidEndpointOverride(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 ElevenLabs 令牌，请设置环境变量 ELEVENLABS_API_KEY 或 XI_API_KEY")
        case .unauthorized: L("ElevenLabs 令牌无效或已过期，请检查 API key")
        case let .server(code): L("ElevenLabs 接口错误（%ld）", code)
        case .invalidResponse: L("ElevenLabs 用量接口返回异常")
        case let .invalidEndpointOverride(key): L("ElevenLabs 端点覆盖 %@ 必须使用 HTTPS 或裸主机名", key)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum ElevenLabsUsageFetcher {
    private static let defaultHost = "https://api.elevenlabs.io"
    private static let subscriptionPath = "user/subscription"
    private static let timeoutSeconds: TimeInterval = 15

    /// 是否配置了 ElevenLabs 令牌（用于在工具面板里把 ElevenLabs 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        for key in ["ELEVENLABS_API_KEY", "XI_API_KEY"] {
            if let v = clean(env[key]) { return v }
        }
        return nil
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// `ELEVENLABS_API_URL` 覆盖：必须能规范化为 HTTPS URL，否则报错。
    static func apiURL(env: [String: String]) throws -> URL {
        guard let raw = clean(env["ELEVENLABS_API_URL"]) else {
            return URL(string: defaultHost)!
        }
        guard let url = normalizedHTTPSURL(from: raw) else {
            throw ElevenLabsUsageError.invalidEndpointOverride("ELEVENLABS_API_URL")
        }
        return url
    }

    /// 把裸主机名补成 https://，并要求最终 scheme 为 https。
    private static func normalizedHTTPSURL(from raw: String) -> URL? {
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// 拼接 subscription 端点：若 baseURL 已以 v1 结尾则只补 user/subscription，否则补 v1/user/subscription。
    static func subscriptionURL(baseURL: URL) -> URL {
        var url = baseURL
        let pathComponents = url.path.split(separator: "/")
        if pathComponents.last == "v1" {
            url.appendPathComponent(subscriptionPath)
        } else {
            url.appendPathComponent("v1/\(subscriptionPath)")
        }
        return url
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw ElevenLabsUsageError.missingToken }

        let baseURL = try apiURL(env: env)
        var request = URLRequest(url: subscriptionURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw ElevenLabsUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as ElevenLabsUsageError {
            throw e
        } catch {
            throw ElevenLabsUsageError.network(error.localizedDescription)
        }

        switch http.statusCode {
        case 200:
            return try parse(data)
        case 401, 403:
            throw ElevenLabsUsageError.unauthorized
        default:
            throw ElevenLabsUsageError.server(http.statusCode)
        }
    }

    // MARK: - 解析

    private struct SubscriptionResponse: Decodable {
        let tier: String?
        let characterCount: Int
        let characterLimit: Int
        let voiceSlotsUsed: Int?
        let professionalVoiceSlotsUsed: Int?
        let voiceLimit: Int?
        let professionalVoiceLimit: Int?
        let status: String?
        let nextCharacterCountResetUnix: Int?

        enum CodingKeys: String, CodingKey {
            case tier
            case characterCount = "character_count"
            case characterLimit = "character_limit"
            case voiceSlotsUsed = "voice_slots_used"
            case professionalVoiceSlotsUsed = "professional_voice_slots_used"
            case voiceLimit = "voice_limit"
            case professionalVoiceLimit = "professional_voice_limit"
            case status
            case nextCharacterCountResetUnix = "next_character_count_reset_unix"
        }
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let decoded: SubscriptionResponse
        do {
            decoded = try JSONDecoder().decode(SubscriptionResponse.self, from: data)
        } catch {
            throw ElevenLabsUsageError.invalidResponse
        }

        // 字符额度 → 已用百分比 used/limit*100。
        let usedPercent: Double
        if decoded.characterLimit > 0 {
            usedPercent = max(0, min(100, Double(decoded.characterCount) / Double(decoded.characterLimit) * 100))
        } else {
            usedPercent = 0
        }

        // 重置时间：优先 next_character_count_reset_unix，缺则 now + 30 天。
        let resetAt = decoded.nextCharacterCountResetUnix
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? Date().addingTimeInterval(30 * 86400)

        // 主窗：字符配额已用百分比（无固定周期）。resetDescription 给出 "已用 / 上限 credits" 文案。
        let primary = RateWindow(
            title: L("字符额度"),
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: resetAt,
            resetDescription: characterSummary(used: decoded.characterCount, limit: decoded.characterLimit))

        // providerCost：用「字符」作为单位承载已用 / 上限的绝对数量，配 next reset 与计费周期文案。
        let providerCost = ProviderCostSnapshot(
            used: Double(decoded.characterCount),
            limit: Double(decoded.characterLimit),
            currencyCode: "Characters",
            period: L("计费周期"),
            resetsAt: resetAt)

        // 额外细分配额：语音槽位、专业语音槽位（CodexBar tertiary/extraRateWindows 对应项）。
        let extras = voiceWindows(
            voiceSlotsUsed: decoded.voiceSlotsUsed,
            voiceLimit: decoded.voiceLimit,
            professionalVoiceSlotsUsed: decoded.professionalVoiceSlotsUsed,
            professionalVoiceLimit: decoded.professionalVoiceLimit)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: extras,
            providerCost: providerCost,
            planName: planType(tier: decoded.tier, status: decoded.status))
    }

    /// 主配额文案："已用 / 上限 credits"。
    private static func characterSummary(used: Int, limit: Int) -> String {
        "\(formatCount(used)) / \(formatCount(limit)) credits"
    }

    /// 语音槽位与专业语音槽位 → conductor extraRateWindows（仅在上限 > 0 时呈现）。
    private static func voiceWindows(
        voiceSlotsUsed: Int?,
        voiceLimit: Int?,
        professionalVoiceSlotsUsed: Int?,
        professionalVoiceLimit: Int?) -> [NamedRateWindow]
    {
        var windows: [NamedRateWindow] = []
        if let used = voiceSlotsUsed, let limit = voiceLimit, limit > 0 {
            windows.append(NamedRateWindow(
                id: "voice-slots",
                title: L("语音槽位"),
                window: RateWindow(
                    title: L("语音槽位"),
                    usedPercent: Double(used) / Double(limit) * 100,
                    resetDescription: "\(used) / \(limit)")))
        }
        if let used = professionalVoiceSlotsUsed, let limit = professionalVoiceLimit, limit > 0 {
            windows.append(NamedRateWindow(
                id: "professional-voices",
                title: L("专业语音"),
                window: RateWindow(
                    title: L("专业语音"),
                    usedPercent: Double(used) / Double(limit) * 100,
                    resetDescription: "\(used) / \(limit)")))
        }
        return windows
    }

    /// 数量千分位格式化（如 100000 → 100,000）。
    private static func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 套餐展示名：tier 下划线转空格并首字母大写，非 active 状态追加后缀；tier 缺失回退 status。
    private static func planType(tier: String?, status: String?) -> String? {
        guard let tier = tier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty else {
            return status
        }
        let statusSuffix: String
        if let status, !status.isEmpty, status.lowercased() != "active" {
            statusSuffix = " · \(status)"
        } else {
            statusSuffix = ""
        }
        return "\(tier.replacingOccurrences(of: "_", with: " ").capitalized)\(statusSuffix)"
    }
}
