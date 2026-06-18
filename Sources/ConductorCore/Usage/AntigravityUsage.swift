import Foundation

/// Antigravity（Google「Antigravity」IDE / Gemini Code Assist 套餐）用量取数。
///
/// 忠实转写自 CodexBar 的 `AntigravityOAuthFetchStrategy` → `AntigravityRemoteUsageFetcher`
/// 这一条**纯 HTTP / 本地凭证**路径（不依赖 `agy` CLI 进程）。取数流程：
///   1. 从本地凭证文件 `~/.codexbar/antigravity/oauth_creds.json`（或环境变量
///      `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON` 注入的 JSON）读 Google OAuth 凭证；
///   2. 令牌将过期则用 `refresh_token` 走 `https://oauth2.googleapis.com/token` 刷新
///      （client_id/secret 优先取凭证内置，其次环境变量，再次从已安装的 Antigravity.app
///      二进制里发现）；
///   3. `Bearer` 调 `https://cloudcode-pa.googleapis.com` 的
///      `v1internal:loadCodeAssist` / `:onboardUser` / `:fetchAvailableModels`
///      / `:retrieveUserQuota`，得到各模型 `remainingFraction`（剩余额度分数）。
///
/// 额度→快照映射：`usedPercent = round((1 - remainingFraction) * 100)`。Antigravity
/// 没有「会话窗口 / 周窗口」概念，按各模型族各自的配额配重置时间。这里照 CodexBar 的
/// 取代表：Claude 族当 session（primary），Gemini Pro 族当 weekly（secondary）；
/// 若拿不到对应族则回退到剩余最少的可用模型。无重置时间则回落 now+30 天。
///
/// 凭证来源说明：`oauth_creds.json` 是 **CodexBar 自己的 OAuth 登录产物**，由 CodexBar 的
/// 登录流程写入，并非 Antigravity IDE 原生写的文件。conductor 没有内置这套登录 UI，
/// 因此只有先在 CodexBar 里登录过、或手动经环境变量注入凭证，本 provider 才会被视作「已配置」。
/// CLI 路径（`agy` REPL + 本地 HTTPS server 探测）未移植——见文件末尾说明。
public enum AntigravityUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case unauthorized
    case missingOAuthClient
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: L("未找到 Antigravity 登录信息，请先在 CodexBar 中用 Google 账号登录 Antigravity")
        case .unauthorized: L("Antigravity 令牌已过期，请重新登录")
        case .missingOAuthClient: L("未找到 Antigravity OAuth 客户端，请安装 Antigravity.app 或设置 ANTIGRAVITY_OAUTH_CLIENT_ID / ANTIGRAVITY_OAUTH_CLIENT_SECRET")
        case let .server(code): L("Antigravity 接口错误（%ld）", code)
        case .invalidResponse: L("Antigravity 用量接口返回异常")
        case let .network(msg): L("网络错误：%@", msg)
        }
    }
}

public enum AntigravityUsageFetcher {
    // MARK: - 端点（照搬 AntigravityRemoteUsageFetcher）

    private static let baseURL = "https://cloudcode-pa.googleapis.com"
    private static let loadCodeAssistEndpoint = "\(baseURL)/v1internal:loadCodeAssist"
    private static let onboardUserEndpoint = "\(baseURL)/v1internal:onboardUser"
    private static let fetchAvailableModelsEndpoint = "\(baseURL)/v1internal:fetchAvailableModels"
    private static let retrieveUserQuotaEndpoint = "\(baseURL)/v1internal:retrieveUserQuota"
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userAgent = "antigravity"
    private static let refreshSafetyWindow: TimeInterval = 60
    private static let timeout: TimeInterval = 30
    private static let environmentCredentialsKey = "ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"

    // MARK: - 可用性判断

    /// 是否存在 Antigravity 凭证（本地 oauth_creds.json 或环境变量注入）。
    /// 仅做便宜的本地存在性 / 解码检查，不发网络。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        loadStoredCredentials(env: env) != nil
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        guard var credentials = loadStoredCredentials(env: env) else {
            throw AntigravityUsageError.notLoggedIn
        }
        guard var accessToken = credentials.accessToken?.trimmedNonEmpty else {
            throw AntigravityUsageError.notLoggedIn
        }

        // 1. 必要时刷新令牌。
        if shouldRefresh(expiryDate: credentials.expiryDate, now: Date()) {
            guard let refreshToken = credentials.refreshToken?.trimmedNonEmpty else {
                throw AntigravityUsageError.notLoggedIn
            }
            let refreshed = try await refreshAccessToken(
                credentials: credentials,
                refreshToken: refreshToken,
                env: env,
                session: session)
            accessToken = refreshed.accessToken
            credentials = refreshed.credentials
        }

        // 2. loadCodeAssist 拿计划 / projectID。
        let claims = extractClaims(from: credentials)
        let codeAssist = try await loadCodeAssist(accessToken: accessToken, session: session)
        let projectID = try await resolveProjectID(
            accessToken: accessToken,
            storedProjectID: credentials.projectID?.trimmedNonEmpty,
            initialResponse: codeAssist,
            session: session)

        // 3. 取各模型额度。
        let quotas = try await fetchModelQuotas(
            accessToken: accessToken,
            projectID: projectID,
            session: session)

        let plan = resolvePlan(response: codeAssist, claims: claims)
        return makeSnapshot(quotas: quotas, planType: plan)
    }

    // MARK: - 凭证加载

    static func credentialsFileURL(env: [String: String]) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("oauth_creds.json")
    }

    static func loadStoredCredentials(env: [String: String]) -> Credentials? {
        // 优先环境变量注入的 JSON（选定账号场景），否则读本地文件。
        if let raw = env[environmentCredentialsKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let data = raw.data(using: .utf8),
           let creds = try? JSONDecoder().decode(Credentials.self, from: data)
        {
            return creds
        }
        let url = credentialsFileURL(env: env)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let creds = try? JSONDecoder().decode(Credentials.self, from: data)
        else { return nil }
        return creds
    }

    private static func shouldRefresh(expiryDate: Date?, now: Date) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate.timeIntervalSince(now) <= refreshSafetyWindow
    }

    // MARK: - 令牌刷新

    private struct RefreshResult {
        let accessToken: String
        let credentials: Credentials
    }

    private static func refreshAccessToken(
        credentials: Credentials,
        refreshToken: String,
        env: [String: String],
        session: URLSession) async throws -> RefreshResult
    {
        let client = try resolveOAuthClient(from: credentials, env: env)

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])

        let (data, http) = try await perform(request, session: session)
        guard http.statusCode == 200 else { throw AntigravityUsageError.unauthorized }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else { throw AntigravityUsageError.invalidResponse }

        var updated = credentials
        updated.accessToken = accessToken
        if let expiresIn = json["expires_in"] as? Double {
            updated.expiryDateMilliseconds = (Date().timeIntervalSince1970 + expiresIn) * 1000
        } else if let expiresIn = json["expires_in"] as? Int {
            updated.expiryDateMilliseconds = (Date().timeIntervalSince1970 + Double(expiresIn)) * 1000
        }
        if let idToken = json["id_token"] as? String { updated.idToken = idToken }
        // 注：CodexBar 此处会把刷新后的凭证写回 oauth_creds.json；conductor 不持有该登录态，
        // 故仅在内存中使用，不回写文件（避免越权改 CodexBar 的存储）。
        return RefreshResult(accessToken: accessToken, credentials: updated)
    }

    private struct OAuthClient {
        let clientID: String
        let clientSecret: String
    }

    private static func resolveOAuthClient(from credentials: Credentials, env: [String: String]) throws -> OAuthClient {
        // 1. 凭证内置。
        if let id = credentials.clientID?.trimmedNonEmpty,
           let secret = credentials.clientSecret?.trimmedNonEmpty
        {
            return OAuthClient(clientID: id, clientSecret: secret)
        }
        // 2. 环境变量。
        if let id = env["ANTIGRAVITY_OAUTH_CLIENT_ID"]?.trimmedNonEmpty,
           let secret = env["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]?.trimmedNonEmpty
        {
            return OAuthClient(clientID: id, clientSecret: secret)
        }
        // 3. 从已安装的 Antigravity.app 二进制里发现。
        if let discovered = discoverClientFromInstalledApp() {
            return discovered
        }
        throw AntigravityUsageError.missingOAuthClient
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.query?.data(using: .utf8)
    }

    // MARK: - Cloud Code 调用

    private static func loadCodeAssist(accessToken: String, session: URLSession) async throws -> CodeAssistResponse {
        let body: [String: Any] = [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        return try await sendRequest(endpoint: loadCodeAssistEndpoint, accessToken: accessToken, body: body, session: session)
    }

    private static func resolveProjectID(
        accessToken: String,
        storedProjectID: String?,
        initialResponse: CodeAssistResponse,
        session: URLSession) async throws -> String?
    {
        if let storedProjectID { return storedProjectID }
        if let projectID = initialResponse.projectID { return projectID }
        guard let tierID = pickOnboardTier(from: initialResponse) else { return nil }

        let onboardBody: [String: Any] = [
            "tierId": tierID,
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        if let onboard: OnboardResponse = try? await sendRequest(
            endpoint: onboardUserEndpoint, accessToken: accessToken, body: onboardBody, session: session),
            let projectID = onboard.projectID
        {
            return projectID
        }
        // onboard 异步：轮询 loadCodeAssist 至多 5 次等 projectID 落地。
        for _ in 0 ..< 5 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let refreshed = try await loadCodeAssist(accessToken: accessToken, session: session)
            if let projectID = refreshed.projectID { return projectID }
        }
        return nil
    }

    private static func fetchModelQuotas(
        accessToken: String,
        projectID: String?,
        session: URLSession) async throws -> [ModelQuota]
    {
        do {
            let response: FetchAvailableModelsResponse = try await sendRequest(
                endpoint: fetchAvailableModelsEndpoint,
                accessToken: accessToken,
                body: projectBody(projectID),
                session: session)
            let quotas = parseModelQuotas(response)
            // 全部满额时再用 retrieveUserQuota 校验真实消耗（与 CodexBar 一致）。
            if shouldVerify(quotas),
               let verified = try? await fetchQuotaBuckets(accessToken: accessToken, projectID: projectID, session: session),
               hasConsumed(verified)
            {
                return mergeVerified(modelQuotas: quotas, verified: verified)
            }
            return quotas
        } catch let error as AntigravityUsageError {
            // fetchAvailableModels 被拒（403）时回退 retrieveUserQuota。
            guard case .server(403) = error else { throw error }
            return (try? await fetchQuotaBuckets(accessToken: accessToken, projectID: projectID, session: session)) ?? []
        }
    }

    private static func fetchQuotaBuckets(
        accessToken: String,
        projectID: String?,
        session: URLSession) async throws -> [ModelQuota]?
    {
        do {
            let response: RetrieveUserQuotaResponse = try await sendRequest(
                endpoint: retrieveUserQuotaEndpoint,
                accessToken: accessToken,
                body: projectBody(projectID),
                session: session)
            return parseQuotaBuckets(response)
        } catch let error as AntigravityUsageError {
            guard case .server(403) = error else { throw error }
            return nil
        }
    }

    private static func projectBody(_ projectID: String?) -> [String: Any] {
        if let projectID = projectID?.trimmedNonEmpty { ["project": projectID] } else { [:] }
    }

    private static func sendRequest<Response: Decodable>(
        endpoint: String,
        accessToken: String,
        body: [String: Any],
        session: URLSession) async throws -> Response
    {
        guard let url = URL(string: endpoint) else { throw AntigravityUsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await perform(request, session: session)
        switch http.statusCode {
        case 200 ... 299:
            do { return try JSONDecoder().decode(Response.self, from: data) }
            catch { throw AntigravityUsageError.invalidResponse }
        case 401:
            throw AntigravityUsageError.unauthorized
        default:
            throw AntigravityUsageError.server(http.statusCode)
        }
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AntigravityUsageError.invalidResponse }
            return (data, http)
        } catch let error as AntigravityUsageError {
            throw error
        } catch {
            throw AntigravityUsageError.network(error.localizedDescription)
        }
    }

    // MARK: - 解析额度

    /// 一个模型的额度（剩余分数 + 重置时间）。
    struct ModelQuota {
        let label: String
        let modelID: String
        let remainingFraction: Double?
        let resetTime: Date?

        /// 剩余百分比 0...100（无数据按 0）。
        var remainingPercent: Double {
            guard let remainingFraction else { return 0 }
            return max(0, min(100, remainingFraction * 100))
        }
    }

    private static func parseModelQuotas(_ response: FetchAvailableModelsResponse) -> [ModelQuota] {
        let models = response.models ?? [:]
        return models.compactMap { modelID, model in
            guard let quotaInfo = model.quotaInfo else { return nil }
            let label = model.displayName?.trimmedNonEmpty ?? model.label?.trimmedNonEmpty ?? modelID
            return ModelQuota(
                label: label,
                modelID: modelID,
                remainingFraction: quotaInfo.remainingFraction,
                resetTime: quotaInfo.resetTime.flatMap(parseResetTime))
        }
    }

    private static func parseQuotaBuckets(_ response: RetrieveUserQuotaResponse) -> [ModelQuota] {
        guard let buckets = response.buckets, !buckets.isEmpty else { return [] }
        var map: [String: (fraction: Double?, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let modelID = bucket.modelId?.trimmedNonEmpty else { continue }
            let next = (bucket.remainingFraction, bucket.resetTime)
            if let existing = map[modelID] {
                let existingValue = existing.fraction ?? .greatestFiniteMagnitude
                let nextValue = next.0 ?? .greatestFiniteMagnitude
                if nextValue < existingValue { map[modelID] = next }
            } else {
                map[modelID] = next
            }
        }
        return map.keys.sorted().compactMap { modelID in
            guard let info = map[modelID] else { return nil }
            return ModelQuota(
                label: modelID,
                modelID: modelID,
                remainingFraction: info.fraction,
                resetTime: info.resetTime.flatMap(parseResetTime))
        }
    }

    private static func shouldVerify(_ quotas: [ModelQuota]) -> Bool {
        guard !quotas.isEmpty else { return false }
        return quotas.allSatisfy { ($0.remainingFraction ?? -1) >= 0.999 }
    }

    private static func hasConsumed(_ quotas: [ModelQuota]) -> Bool {
        quotas.contains { ($0.remainingFraction ?? 1.0) < 0.999 }
    }

    private static func mergeVerified(modelQuotas: [ModelQuota], verified: [ModelQuota]) -> [ModelQuota] {
        var verifiedByID = Dictionary(uniqueKeysWithValues: verified.map { (quotaKey($0), $0) })
        var merged = modelQuotas.map { quota -> ModelQuota in
            guard let v = verifiedByID.removeValue(forKey: quotaKey(quota)) else { return quota }
            return ModelQuota(
                label: quota.label,
                modelID: quota.modelID,
                remainingFraction: v.remainingFraction ?? quota.remainingFraction,
                resetTime: v.resetTime ?? quota.resetTime)
        }
        merged.append(contentsOf: verifiedByID.values
            .filter { $0.remainingFraction != nil }
            .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending })
        return merged
    }

    private static func quotaKey(_ quota: ModelQuota) -> String {
        quota.modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func parseResetTime(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    // MARK: - 模型族 → 快照映射

    private enum Family { case claude, geminiPro, geminiFlash, unknown }

    private static func family(of quota: ModelQuota) -> Family {
        let text = (quota.modelID + " " + quota.label).lowercased()
        if text.contains("claude") { return .claude }
        if text.contains("gemini"), text.contains("pro") { return .geminiPro }
        if text.contains("gemini"), text.contains("flash") { return .geminiFlash }
        return .unknown
    }

    private static func isSummaryCandidate(_ quota: ModelQuota) -> Bool {
        let text = (quota.modelID + " " + quota.label).lowercased()
        let isLite = text.contains("lite")
        let isAutocomplete = text.contains("autocomplete") || quota.modelID.lowercased().hasPrefix("tab_")
        let isImage = text.contains("image")
        return family(of: quota) != .unknown && !isLite && !isAutocomplete && !isImage
    }

    /// 在某一族里取代表配额：优先有 remainingFraction 的，再取剩余最少的。
    private static func representative(for family: Family, in quotas: [ModelQuota]) -> ModelQuota? {
        let candidates = quotas.filter { self.family(of: $0) == family }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            let lhsHas = lhs.remainingFraction != nil
            let rhsHas = rhs.remainingFraction != nil
            if lhsHas != rhsHas { return lhsHas && !rhsHas }
            if lhs.remainingPercent != rhs.remainingPercent { return lhs.remainingPercent < rhs.remainingPercent }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private static func makeSnapshot(quotas: [ModelQuota], planType: String?) -> UsageSnapshot {
        let summaryModels = quotas.filter { isSummaryCandidate($0) && $0.remainingFraction != nil }
        let claude = representative(for: .claude, in: summaryModels)
        let geminiPro = representative(for: .geminiPro, in: summaryModels)
        let geminiFlash = representative(for: .geminiFlash, in: summaryModels)

        // primary = Claude 族（无则回退到剩余最少的可用模型）；secondary = Gemini Pro 族；
        // tertiary = Gemini Flash 族（照搬 CodexBar 的 `tertiary: tertiary`）。
        let primaryQuota = claude ?? geminiPro ?? geminiFlash ?? summaryModels.min {
            $0.remainingPercent < $1.remainingPercent
        }
        let secondaryQuota: ModelQuota? = (claude != nil) ? geminiPro : nil
        let tertiaryQuota: ModelQuota? = geminiFlash

        // extraRateWindows：把全部 summary 模型按剩余%（再按标签）排序后逐条建命名窗，
        // 照搬 CodexBar 的 `extraRateWindows: extraWindows`（id=modelID、title=label、
        // window=该模型的 RateWindow）。空则不带额外窗。
        let extraWindows = summaryModels
            .sorted { lhs, rhs in
                if lhs.remainingPercent != rhs.remainingPercent {
                    return lhs.remainingPercent < rhs.remainingPercent
                }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .map { quota in
                NamedRateWindow(id: quota.modelID, title: quota.label, window: rateWindow(for: quota))
            }

        return UsageSnapshot(
            primary: primaryQuota.map(rateWindow(for:)),
            secondary: secondaryQuota.map(rateWindow(for:)),
            tertiary: tertiaryQuota.map(rateWindow(for:)),
            extraRateWindows: extraWindows,
            planName: planType)
    }

    /// 单条额度 → RateWindow。Antigravity 无周期窗口，windowMinutes 记 nil；
    /// usedPercent = 100 - 剩余%；resetsAt 取重置时间（无则 now+30 天）。
    private static func rateWindow(for quota: ModelQuota) -> RateWindow {
        let used = max(0, min(100, (100 - quota.remainingPercent).rounded()))
        let reset = quota.resetTime ?? Date().addingTimeInterval(30 * 86400)
        return RateWindow(
            title: quota.label,
            usedPercent: used,
            windowMinutes: nil,
            resetsAt: reset)
    }

    // MARK: - 计划解析

    private struct TokenClaims {
        let email: String?
        let hostedDomain: String?
    }

    private static func extractClaims(from credentials: Credentials) -> TokenClaims {
        let fromToken = claimsFromIDToken(credentials.idToken)
        return TokenClaims(
            email: fromToken.email ?? credentials.email?.trimmedNonEmpty,
            hostedDomain: fromToken.hostedDomain)
    }

    private static func claimsFromIDToken(_ idToken: String?) -> TokenClaims {
        guard let idToken else { return TokenClaims(email: nil, hostedDomain: nil) }
        let parts = idToken.components(separatedBy: ".")
        guard parts.count >= 2 else { return TokenClaims(email: nil, hostedDomain: nil) }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return TokenClaims(email: nil, hostedDomain: nil) }
        return TokenClaims(
            email: (json["email"] as? String)?.trimmedNonEmpty,
            hostedDomain: (json["hd"] as? String)?.trimmedNonEmpty)
    }

    private static func resolvePlan(response: CodeAssistResponse, claims: TokenClaims) -> String? {
        if let planType = response.planInfo?.planType?.trimmedNonEmpty { return planType }
        switch (response.currentTier?.id?.trimmedNonEmpty, claims.hostedDomain) {
        case ("standard-tier", _): return "Paid"
        case ("free-tier", .some): return "Workspace"
        case ("free-tier", .none): return "Free"
        case ("legacy-tier", _): return "Legacy"
        default: return response.currentTier?.name?.trimmedNonEmpty
        }
    }

    private static func pickOnboardTier(from response: CodeAssistResponse) -> String? {
        if let defaultTier = response.allowedTiers?
            .first(where: { $0.isDefault == true && $0.id?.trimmedNonEmpty != nil })?.id?.trimmedNonEmpty
        { return defaultTier }
        if let firstTier = response.allowedTiers?.first(where: { $0.id?.trimmedNonEmpty != nil })?.id?.trimmedNonEmpty {
            return firstTier
        }
        if let paidTier = response.paidTier?.id?.trimmedNonEmpty { return paidTier }
        return response.currentTier?.id?.trimmedNonEmpty
    }

    // MARK: - 从已安装 App 二进制发现 OAuth 客户端（照搬 AntigravityOAuthConfig）

    private static func discoverClientFromInstalledApp() -> OAuthClient? {
        let fileManager = FileManager.default
        for url in candidateOAuthClientArtifactURLs(fileManager: fileManager)
            where fileManager.fileExists(atPath: url.path)
        {
            guard let data = try? Data(contentsOf: url),
                  let client = parseClient(fromArtifactData: data)
            else { continue }
            return client
        }
        return nil
    }

    private static func candidateOAuthClientArtifactURLs(fileManager: FileManager) -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        let relativePaths = [
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
            "Contents/Resources/app/out/main.js",
            "Contents/Resources/bin/language_server",
            "Contents/Resources/bin/language_server_macos",
        ]
        var bundleURLs: [URL] = []
        var seen = Set<String>()
        for root in roots {
            let candidate = root.appendingPathComponent("Antigravity.app", isDirectory: true)
            if seen.insert(candidate.standardizedFileURL.path).inserted { bundleURLs.append(candidate) }
            let appURLs = (try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for appURL in appURLs where appURL.pathExtension == "app" && isAntigravityAppBundle(appURL) {
                if seen.insert(appURL.standardizedFileURL.path).inserted { bundleURLs.append(appURL) }
            }
        }
        return bundleURLs.flatMap { bundle in relativePaths.map { bundle.appendingPathComponent($0) } }
    }

    private static func isAntigravityAppBundle(_ url: URL) -> Bool {
        switch Bundle(url: url)?.bundleIdentifier {
        case "com.google.antigravity", "com.google.antigravity-ide": true
        default: false
        }
    }

    private static func parseClient(fromArtifactData data: Data) -> OAuthClient? {
        if let content = String(data: data, encoding: .utf8),
           let client = parseClient(fromArtifactText: content)
        { return client }

        let clientIDs = clientIDs(in: data)
        let clientSecrets = clientSecrets(in: data)
        guard !clientIDs.isEmpty, !clientSecrets.isEmpty else { return nil }

        if clientSecrets.count == 1, clientIDs.count > 1 {
            return OAuthClient(clientID: clientIDs[clientIDs.count - 1], clientSecret: clientSecrets[0])
        }
        let secret: String = if clientSecrets.count == clientIDs.count, clientSecrets.count > 1 {
            clientSecrets[clientSecrets.count - 1]
        } else {
            clientSecrets[0]
        }
        return OAuthClient(clientID: clientIDs[0], clientSecret: secret)
    }

    private static func parseClient(fromArtifactText content: String) -> OAuthClient? {
        let marker = "vs/platform/cloudCode/common/oauthClient.js"
        let searchStart = content.range(of: marker)?.lowerBound ?? content.startIndex
        let searchEnd = content.index(searchStart, offsetBy: 4000, limitedBy: content.endIndex) ?? content.endIndex
        let haystack = String(content[searchStart ..< searchEnd])
        guard let clientID = firstMatch(
            pattern: #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#, in: haystack),
            let clientSecret = firstMatch(pattern: #"GOCSPX-[A-Za-z0-9_-]{28}"#, in: haystack)
        else { return nil }
        return OAuthClient(clientID: clientID, clientSecret: clientSecret)
    }

    private static func clientIDs(in data: Data) -> [String] {
        let suffix = Data(".apps.googleusercontent.com".utf8)
        var searchRange = data.startIndex ..< data.endIndex
        var values: [String] = []
        while let range = data.range(of: suffix, options: [], in: searchRange) {
            var start = range.lowerBound
            while start > data.startIndex {
                let previous = data.index(before: start)
                guard isOAuthByte(data[previous]) else { break }
                start = previous
            }
            if let candidate = String(data: Data(data[start ..< range.upperBound]), encoding: .ascii),
               let clientID = firstMatch(
                   pattern: #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#, in: candidate)
            { values.append(clientID) }
            searchRange = range.upperBound ..< data.endIndex
        }
        return unique(values)
    }

    private static func clientSecrets(in data: Data) -> [String] {
        let prefix = Data("GOCSPX-".utf8)
        let secretLength = 35
        var searchRange = data.startIndex ..< data.endIndex
        var values: [String] = []
        while let range = data.range(of: prefix, options: [], in: searchRange) {
            let end = range.lowerBound + secretLength
            if end <= data.endIndex {
                let candidateData = Data(data[range.lowerBound ..< end])
                if candidateData.dropFirst(prefix.count).allSatisfy(isOAuthByte),
                   let candidate = String(data: candidateData, encoding: .ascii)
                { values.append(candidate) }
            }
            searchRange = range.upperBound ..< data.endIndex
        }
        return unique(values)
    }

    private static func isOAuthByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122) || byte == 45 || byte == 95
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text)
        else { return nil }
        return String(text[swiftRange])
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - 凭证模型（照搬 AntigravityOAuthCredentials 的解码键，snake/camel 双兼容）

    struct Credentials: Decodable {
        var accessToken: String?
        var refreshToken: String?
        var expiryDateMilliseconds: Double?
        var idToken: String?
        var email: String?
        var projectID: String?
        var clientID: String?
        var clientSecret: String?

        var expiryDate: Date? {
            guard let expiryDateMilliseconds else { return nil }
            return Date(timeIntervalSince1970: expiryDateMilliseconds / 1000)
        }

        enum CodingKeys: String, CodingKey {
            case accessTokenSnake = "access_token"
            case accessTokenCamel = "accessToken"
            case refreshTokenSnake = "refresh_token"
            case refreshTokenCamel = "refreshToken"
            case expiryDateSnake = "expiry_date"
            case expiresAtCamel = "expiresAt"
            case idTokenSnake = "id_token"
            case idTokenCamel = "idToken"
            case email
            case projectIDSnake = "project_id"
            case projectIDCamel = "projectId"
            case clientIDSnake = "client_id"
            case clientIDCamel = "clientId"
            case clientSecretSnake = "client_secret"
            case clientSecretCamel = "clientSecret"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decodeIfPresent(String.self, forKey: .accessTokenSnake)
                ?? c.decodeIfPresent(String.self, forKey: .accessTokenCamel)
            refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshTokenSnake)
                ?? c.decodeIfPresent(String.self, forKey: .refreshTokenCamel)
            idToken = try c.decodeIfPresent(String.self, forKey: .idTokenSnake)
                ?? c.decodeIfPresent(String.self, forKey: .idTokenCamel)
            email = try c.decodeIfPresent(String.self, forKey: .email)
            projectID = try c.decodeIfPresent(String.self, forKey: .projectIDSnake)
                ?? c.decodeIfPresent(String.self, forKey: .projectIDCamel)
            clientID = try c.decodeIfPresent(String.self, forKey: .clientIDSnake)
                ?? c.decodeIfPresent(String.self, forKey: .clientIDCamel)
            clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecretSnake)
                ?? c.decodeIfPresent(String.self, forKey: .clientSecretCamel)
            if let ms = try c.decodeIfPresent(Double.self, forKey: .expiryDateSnake)
                ?? c.decodeIfPresent(Double.self, forKey: .expiresAtCamel)
            {
                expiryDateMilliseconds = ms
            } else if let ms = try c.decodeIfPresent(Int.self, forKey: .expiryDateSnake)
                ?? c.decodeIfPresent(Int.self, forKey: .expiresAtCamel)
            {
                expiryDateMilliseconds = Double(ms)
            } else {
                expiryDateMilliseconds = nil
            }
        }
    }

    // MARK: - 响应模型

    private struct CodeAssistResponse: Decodable {
        let planInfo: PlanInfo?
        let currentTier: TierInfo?
        let paidTier: TierInfo?
        let allowedTiers: [AllowedTier]?
        let cloudaicompanionProject: ProjectReference?

        var projectID: String? {
            cloudaicompanionProject?.value?.trimmedNonEmpty
        }
    }

    private struct PlanInfo: Decodable { let planType: String? }
    private struct TierInfo: Decodable { let id: String?; let name: String? }
    private struct AllowedTier: Decodable { let id: String?; let isDefault: Bool? }

    private struct ProjectReference: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let stringValue = try? single.decode(String.self)
            {
                value = stringValue
                return
            }
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            value = try keyed.decodeIfPresent(String.self, forKey: .id)
                ?? keyed.decodeIfPresent(String.self, forKey: .projectID)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case projectID = "projectId"
        }
    }

    private struct OnboardResponse: Decodable {
        let response: Inner?
        var projectID: String? { response?.cloudaicompanionProject?.value?.trimmedNonEmpty }
        struct Inner: Decodable { let cloudaicompanionProject: ProjectReference? }
    }

    private struct FetchAvailableModelsResponse: Decodable {
        let models: [String: RemoteModel]?
    }

    private struct RemoteModel: Decodable {
        let displayName: String?
        let label: String?
        let quotaInfo: RemoteQuotaInfo?
    }

    private struct RemoteQuotaInfo: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
    }

    private struct RetrieveUserQuotaResponse: Decodable {
        let buckets: [QuotaBucket]?
    }

    private struct QuotaBucket: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }
}

extension Optional where Wrapped == String {
    fileprivate var trimmedNonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension String {
    fileprivate var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
