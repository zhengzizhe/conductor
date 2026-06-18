import Foundation

/// Gemini（Gemini CLI / Google 账号）用量取数。取数路径摘自 CodexBar `GeminiStatusProbe`，
/// 自足、不依赖浏览器 cookie：
/// 1. 读 `~/.gemini/oauth_creds.json` 的 OAuth 凭证；过期则用 gemini-cli 安装包里内嵌的
///    OAUTH_CLIENT_ID/SECRET 走 Google OAuth 刷新 token；
/// 2. `loadCodeAssist` 取 tier/project，必要时从 cloudresourcemanager 发现 project；
/// 3. POST `retrieveUserQuota` 取各模型剩余配额，按 Pro / Flash 归并成会话/周两个窗口。
///
/// 复用 `CodexUsageSnapshot` 作为通用「会话/周」形状：Pro 模型 → session，Flash 模型 → weekly。
public enum GeminiUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case unsupportedAuthType(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: L("未找到 Gemini 登录信息，请先运行 `gemini` 登录")
        case let .unsupportedAuthType(t): L("Gemini 当前为 %@ 认证，仅支持 Google 账号（OAuth）", t)
        case let .apiError(m): L("Gemini 接口错误：%@", m)
        case let .parseFailed(m): L("Gemini 用量解析失败：%@", m)
        }
    }
}

public enum GeminiUsageFetcher {
    private static let quotaEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let projectsEndpoint = "https://cloudresourcemanager.googleapis.com/v1/projects"
    private static let tokenRefreshEndpoint = "https://oauth2.googleapis.com/token"
    private static let credentialsPath = "/.gemini/oauth_creds.json"
    private static let settingsPath = "/.gemini/settings.json"
    private static let dayWindowSeconds = 24 * 60 * 60

    /// 是否存在 Gemini OAuth 凭证文件。
    public static func hasCredentials(homeDirectory: String = NSHomeDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: homeDirectory + credentialsPath)
    }

    public static func fetch(
        homeDirectory: String = NSHomeDirectory(),
        timeout: TimeInterval = 15,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        // 只支持 OAuth 个人账号；API key / Vertex 明确不支持。
        switch authType(homeDirectory: homeDirectory) {
        case "api-key": throw GeminiUsageError.unsupportedAuthType("API key")
        case "vertex-ai": throw GeminiUsageError.unsupportedAuthType("Vertex AI")
        default: break
        }

        let load: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await session.data(for: $0) }

        var creds = try loadCredentials(homeDirectory: homeDirectory)
        var accessToken = (creds.accessToken?.isEmpty == false) ? creds.accessToken : nil
        let expired = creds.expiryDate.map { $0 < Date() } ?? true
        if accessToken == nil || expired {
            guard let refresh = creds.refreshToken, !refresh.isEmpty else { throw GeminiUsageError.notLoggedIn }
            accessToken = try await refreshAccessToken(
                refreshToken: refresh, homeDirectory: homeDirectory, timeout: timeout, load: load)
            creds = (try? loadCredentials(homeDirectory: homeDirectory)) ?? creds
        }
        guard let token = accessToken else { throw GeminiUsageError.notLoggedIn }

        let plan = await loadTierPlan(token: token, timeout: timeout, load: load)
        var projectId = plan.projectId
        if projectId == nil {
            projectId = try? await discoverProjectId(token: token, timeout: timeout, load: load)
        }

        guard let url = URL(string: quotaEndpoint) else { throw GeminiUsageError.apiError("bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((projectId.map { "{\"project\": \"\($0)\"}" } ?? "{}").utf8)

        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse else { throw GeminiUsageError.apiError("no response") }
        if http.statusCode == 401 { throw GeminiUsageError.notLoggedIn }
        guard http.statusCode == 200 else { throw GeminiUsageError.apiError("HTTP \(http.statusCode)") }

        return try parseQuota(data, planType: plan.planLabel)
    }

    // MARK: - 认证类型 / 凭证

    private static func authType(homeDirectory: String) -> String {
        let url = URL(fileURLWithPath: homeDirectory + settingsPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selected = auth["selectedType"] as? String
        else { return "unknown" }
        return selected
    }

    private struct Creds {
        var accessToken: String?
        var idToken: String?
        var refreshToken: String?
        var expiryDate: Date?
    }

    private static func loadCredentials(homeDirectory: String) throws -> Creds {
        let url = URL(fileURLWithPath: homeDirectory + credentialsPath)
        guard let data = try? Data(contentsOf: url) else { throw GeminiUsageError.notLoggedIn }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiUsageError.parseFailed("bad credentials file")
        }
        var expiry: Date?
        if let ms = json["expiry_date"] as? Double { expiry = Date(timeIntervalSince1970: ms / 1000) }
        return Creds(
            accessToken: json["access_token"] as? String,
            idToken: json["id_token"] as? String,
            refreshToken: json["refresh_token"] as? String,
            expiryDate: expiry)
    }

    // MARK: - Token 刷新（需 gemini-cli 内嵌的 OAuth client id/secret）

    private static func refreshAccessToken(
        refreshToken: String,
        homeDirectory: String,
        timeout: TimeInterval,
        load: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> String
    {
        guard let oauth = extractOAuthClient() else {
            throw GeminiUsageError.apiError(L("找不到 Gemini CLI 的 OAuth 配置"))
        }
        guard let url = URL(string: tokenRefreshEndpoint) else { throw GeminiUsageError.apiError("bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([
            "client_id=\(oauth.clientId)",
            "client_secret=\(oauth.clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&").utf8)

        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String
        else { throw GeminiUsageError.notLoggedIn }

        // 回写新 token / 过期时间。
        updateStoredCredentials(json, homeDirectory: homeDirectory)
        return newToken
    }

    private static func updateStoredCredentials(_ refresh: [String: Any], homeDirectory: String) {
        let url = URL(fileURLWithPath: homeDirectory + credentialsPath)
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let t = refresh["access_token"] { json["access_token"] = t }
        if let id = refresh["id_token"] { json["id_token"] = id }
        if let exp = refresh["expires_in"] as? Double {
            json["expiry_date"] = (Date().timeIntervalSince1970 + exp) * 1000
        }
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? out.write(to: url, options: .atomic)
        }
    }

    private struct OAuthClient { let clientId: String; let clientSecret: String }

    /// 从 gemini-cli 安装目录的 `oauth2.js` 里正则抠出内嵌的 client id/secret（与 CLI 同款凭据）。
    private static func extractOAuthClient() -> OAuthClient? {
        let env = ProcessInfo.processInfo.environment
        guard let geminiPath = BinaryLocator.resolveGeminiBinary(env: env, loginPATH: LoginShellPathCache.shared.current)
            ?? TTYCommandRunner.which("gemini")
        else { return nil }
        let real = URL(fileURLWithPath: geminiPath).resolvingSymlinksInPath().path

        if let c = extractFromLegacyPaths(realGeminiPath: real) { return c }
        if let root = findPackageRoot(startingAt: real), let c = extractFromPackageRoot(root) { return c }
        return nil
    }

    private static func extractFromLegacyPaths(realGeminiPath: String) -> OAuthClient? {
        let binDir = (realGeminiPath as NSString).deletingLastPathComponent
        let baseDir = (binDir as NSString).deletingLastPathComponent
        let oauthFile = "dist/src/code_assist/oauth2.js"
        let oauthSub = "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/\(oauthFile)"
        let nixSub = "share/gemini-cli/node_modules/@google/gemini-cli-core/\(oauthFile)"
        let paths = [
            "\(baseDir)/libexec/lib/\(oauthSub)",
            "\(baseDir)/lib/\(oauthSub)",
            "\(baseDir)/\(nixSub)",
            "\(baseDir)/../gemini-cli-core/\(oauthFile)",
            "\(baseDir)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ]
        for path in paths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let c = parseOAuthClient(from: content) { return c }
        }
        return nil
    }

    private static func extractFromPackageRoot(_ packageRoot: String) -> OAuthClient? {
        let oauthFile = "dist/src/code_assist/oauth2.js"
        let candidates = [
            "\(packageRoot)/\(oauthFile)",
            "\(packageRoot)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ]
        for path in candidates {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let c = parseOAuthClient(from: content) { return c }
        }
        return nil
    }

    private static func findPackageRoot(startingAt path: String) -> String? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue {
            url.deleteLastPathComponent()
        }
        for _ in 0...8 {
            for sub in ["package.json",
                        "lib/node_modules/@google/gemini-cli/package.json",
                        "libexec/lib/node_modules/@google/gemini-cli/package.json"]
            {
                let pkg = url.appendingPathComponent(sub)
                if let data = try? Data(contentsOf: pkg),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["name"] as? String == "@google/gemini-cli"
                {
                    return pkg.deletingLastPathComponent().path
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    private static func parseOAuthClient(from content: String) -> OAuthClient? {
        let idPattern = #"(?:const|let|var)?\s*OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]\s*;"#
        let secretPattern = #"(?:const|let|var)?\s*OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]\s*;"#
        guard let idRe = try? NSRegularExpression(pattern: idPattern),
              let secRe = try? NSRegularExpression(pattern: secretPattern) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let idM = idRe.firstMatch(in: content, range: range), let idR = Range(idM.range(at: 1), in: content),
              let secM = secRe.firstMatch(in: content, range: range), let secR = Range(secM.range(at: 1), in: content)
        else { return nil }
        return OAuthClient(clientId: String(content[idR]), clientSecret: String(content[secR]))
    }

    // MARK: - tier / project

    private struct TierPlan { let planLabel: String?; let projectId: String? }

    private static func loadTierPlan(
        token: String,
        timeout: TimeInterval,
        load: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async -> TierPlan
    {
        guard let url = URL(string: loadCodeAssistEndpoint) else { return TierPlan(planLabel: nil, projectId: nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8)

        guard let (data, response) = try? await load(request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return TierPlan(planLabel: nil, projectId: nil) }

        var projectId: String?
        if let p = json["cloudaicompanionProject"] as? String { projectId = p }
        else if let p = json["cloudaicompanionProject"] as? [String: Any] {
            projectId = (p["id"] as? String) ?? (p["projectId"] as? String)
        }
        let tier = (json["currentTier"] as? [String: Any])?["id"] as? String
        let label: String? = switch tier {
        case "standard-tier": "Paid"
        case "free-tier": "Free"
        case "legacy-tier": "Legacy"
        default: nil
        }
        return TierPlan(planLabel: label, projectId: projectId?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func discoverProjectId(
        token: String,
        timeout: TimeInterval,
        load: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> String?
    {
        guard let url = URL(string: projectsEndpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await load(request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]]
        else { return nil }
        for project in projects {
            guard let id = project["projectId"] as? String else { continue }
            if id.hasPrefix("gen-lang-client") { return id }
            if let labels = project["labels"] as? [String: String], labels["generative-language"] != nil { return id }
        }
        return nil
    }

    // MARK: - 配额解析 → CodexUsageSnapshot

    private struct QuotaBucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let modelId: String?
    }

    private struct QuotaResponse: Decodable { let buckets: [QuotaBucket]? }

    static func parseQuota(_ data: Data, planType: String?) throws -> CodexUsageSnapshot {
        let response = try JSONDecoder().decode(QuotaResponse.self, from: data)
        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw GeminiUsageError.parseFailed("no quota buckets")
        }
        // 每个模型取最低剩余（通常是输入 token 桶）。
        var perModel: [String: (fraction: Double, reset: String?)] = [:]
        for bucket in buckets {
            guard let model = bucket.modelId, let frac = bucket.remainingFraction else { continue }
            if let existing = perModel[model] {
                if frac < existing.fraction { perModel[model] = (frac, bucket.resetTime) }
            } else {
                perModel[model] = (frac, bucket.resetTime)
            }
        }

        func lowest(_ predicate: (String) -> Bool) -> (used: Int, reset: Date?)? {
            let matching = perModel.filter { predicate($0.key.lowercased()) }
            guard let entry = matching.min(by: { $0.value.fraction < $1.value.fraction }) else { return nil }
            let usedPercent = Int(((1 - entry.value.fraction) * 100).rounded())
            let clamped = max(0, Swift.min(100, usedPercent))
            return (clamped, entry.value.reset.flatMap(parseISO8601))
        }

        func isFlashLite(_ id: String) -> Bool { id.contains("flash-lite") }
        func isFlash(_ id: String) -> Bool { id.contains("flash") && !isFlashLite(id) }
        func isPro(_ id: String) -> Bool { id.contains("pro") }

        func window(_ q: (used: Int, reset: Date?)?) -> CodexUsageSnapshot.Window? {
            guard let q else { return nil }
            return CodexUsageSnapshot.Window(
                usedPercent: q.used,
                resetAt: q.reset ?? Date().addingTimeInterval(TimeInterval(dayWindowSeconds)),
                windowSeconds: dayWindowSeconds)
        }

        // Pro → 会话窗；Flash（无则 FlashLite）→ 周窗。
        let pro = window(lowest(isPro))
        let flash = window(lowest(isFlash)) ?? window(lowest(isFlashLite))
        guard pro != nil || flash != nil else { throw GeminiUsageError.parseFailed("no usable model quota") }
        return CodexUsageSnapshot(planType: planType, session: pro, weekly: flash)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
