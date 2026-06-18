import Foundation

/// Warp（Warp 终端 AI 请求额度）用量取数。忠实摘自 CodexBar `Warp` provider，自足、不依赖 cookie：
/// 用环境变量里的 API key 走 `Bearer` POST `https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo`，
/// 解析 `requestLimitInfo`（请求额度/已用/下次刷新）与 `bonusGrants`（赠送/加购额度）。账号级（与具体 CLI 无关）。
///
/// 环境变量：`WARP_API_KEY` / `WARP_TOKEN`（其一即可）。CodexBar 的 `ProviderTokenResolver.warpResolution`
/// 仅解析环境变量，无本地凭证文件、无 cookie，故此处只用 token。
///
/// 坑：Warp 的 GraphQL 端点前有边缘限流，User-Agent 必须匹配官方客户端模式（如 `Warp/1.0`），
/// 否则返回 HTTP 429「Rate exceeded.」。同时需带一组 `x-warp-*` 头与 osContext 变量。
public enum WarpUsageError: LocalizedError, Sendable {
    case missingToken
    case server(Int)
    case invalidResponse
    case apiError(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L("未找到 Warp 令牌，请设置环境变量 WARP_API_KEY 或 WARP_TOKEN")
        case let .server(code): L("Warp 接口错误（%ld）", code)
        case .invalidResponse: L("Warp 用量接口返回异常")
        case let .apiError(m): L("Warp API 错误：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum WarpUsageFetcher {
    private static let apiURL = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    private static let clientID = "warp-app"
    /// Warp 的 GraphQL 端点前有边缘限流，User-Agent 不匹配官方客户端模式会被 429。
    private static let userAgent = "Warp/1.0"

    private static let graphQLQuery = """
    query GetRequestLimitInfo($requestContext: RequestContext!) {
      user(requestContext: $requestContext) {
        __typename
        ... on UserOutput {
          user {
            requestLimitInfo {
              isUnlimited
              nextRefreshTime
              requestLimit
              requestsUsedSinceLastRefresh
            }
            bonusGrants {
              requestCreditsGranted
              requestCreditsRemaining
              expiration
            }
            workspaces {
              bonusGrantsInfo {
                grants {
                  requestCreditsGranted
                  requestCreditsRemaining
                  expiration
                }
              }
            }
          }
        }
      }
    }
    """

    /// 是否配置了 Warp 令牌（用于在工具面板里把 Warp 视作「可用」）。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        token(env: env) != nil
    }

    static func token(env: [String: String]) -> String? {
        for key in ["WARP_API_KEY", "WARP_TOKEN"] {
            if let v = clean(env[key]) { return v }
        }
        return nil
    }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        guard let apiKey = token(env: env) else { throw WarpUsageError.missingToken }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientID, forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osVersionString, forHTTPHeaderField: "x-warp-os-version")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let variables: [String: Any] = [
            "requestContext": [
                "clientContext": [:] as [String: Any],
                "osContext": [
                    "category": "macOS",
                    "name": "macOS",
                    "version": osVersionString,
                ] as [String: Any],
            ] as [String: Any],
        ]
        let body: [String: Any] = [
            "query": graphQLQuery,
            "variables": variables,
            "operationName": "GetRequestLimitInfo",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw WarpUsageError.invalidResponse }
            data = d
            http = h
        } catch let e as WarpUsageError {
            throw e
        } catch {
            throw WarpUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else { throw WarpUsageError.server(http.statusCode) }
        return try parse(data)
    }

    // MARK: - 解析

    static func parse(_ data: Data) throws -> CodexUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = root as? [String: Any]
        else { throw WarpUsageError.invalidResponse }

        // GraphQL errors（HTTP 200 也可能带 errors）。
        if let rawErrors = json["errors"] as? [Any], !rawErrors.isEmpty {
            let messages = rawErrors.compactMap(graphQLErrorMessage(from:))
            throw WarpUsageError.apiError(messages.isEmpty ? "GraphQL request failed." : messages.prefix(3).joined(separator: " | "))
        }

        guard let dataObj = json["data"] as? [String: Any],
              let userObj = dataObj["user"] as? [String: Any]
        else { throw WarpUsageError.invalidResponse }

        let typeName = (userObj["__typename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let innerUserObj = userObj["user"] as? [String: Any],
              let limitInfo = innerUserObj["requestLimitInfo"] as? [String: Any]
        else {
            if let typeName, !typeName.isEmpty, typeName != "UserOutput" {
                throw WarpUsageError.apiError("Unexpected user type '\(typeName)'.")
            }
            throw WarpUsageError.invalidResponse
        }

        let isUnlimited = boolValue(limitInfo["isUnlimited"])
        let requestLimit = intValue(limitInfo["requestLimit"])
        let requestsUsed = intValue(limitInfo["requestsUsedSinceLastRefresh"])
        let nextRefreshTime = (limitInfo["nextRefreshTime"] as? String).flatMap(parseDate)

        // session 窗：请求额度（已用/总额 → 百分比）。无周期信息时回退 now+30 天。
        let usedPercent: Int = if isUnlimited {
            0
        } else if requestLimit > 0 {
            max(0, min(100, Int((Double(requestsUsed) / Double(requestLimit) * 100).rounded())))
        } else {
            0
        }
        let sessionWindow = CodexUsageSnapshot.Window(
            usedPercent: usedPercent,
            resetAt: nextRefreshTime ?? Date().addingTimeInterval(30 * 24 * 3600),
            windowSeconds: 0)

        // weekly 窗：合并的赠送/加购额度（user 级 + workspace 级）。无赠送额度则为 nil。
        let bonus = parseBonusCredits(from: innerUserObj)
        let weeklyWindow: CodexUsageSnapshot.Window?
        if bonus.total > 0 || bonus.remaining > 0 {
            let bonusUsedPercent: Int
            if bonus.total > 0 {
                let used = max(0, bonus.total - bonus.remaining)
                bonusUsedPercent = max(0, min(100, Int((Double(used) / Double(bonus.total) * 100).rounded())))
            } else {
                bonusUsedPercent = bonus.remaining > 0 ? 0 : 100
            }
            weeklyWindow = CodexUsageSnapshot.Window(
                usedPercent: bonusUsedPercent,
                resetAt: bonus.nextExpiration ?? Date().addingTimeInterval(30 * 24 * 3600),
                windowSeconds: 0)
        } else {
            weeklyWindow = nil
        }

        return CodexUsageSnapshot(planType: nil, session: sessionWindow, weekly: weeklyWindow)
    }

    // MARK: - 赠送额度

    private struct BonusGrant {
        let granted: Int
        let remaining: Int
        let expiration: Date?
    }

    private struct BonusSummary {
        let remaining: Int
        let total: Int
        let nextExpiration: Date?
    }

    private static func parseBonusCredits(from userObj: [String: Any]) -> BonusSummary {
        var grants: [BonusGrant] = []

        // user 级赠送额度。
        if let bonusGrants = userObj["bonusGrants"] as? [[String: Any]] {
            for grant in bonusGrants { grants.append(parseBonusGrant(from: grant)) }
        }

        // workspace 级赠送额度。
        if let workspaces = userObj["workspaces"] as? [[String: Any]] {
            for workspace in workspaces {
                if let bonusGrantsInfo = workspace["bonusGrantsInfo"] as? [String: Any],
                   let workspaceGrants = bonusGrantsInfo["grants"] as? [[String: Any]]
                {
                    for grant in workspaceGrants { grants.append(parseBonusGrant(from: grant)) }
                }
            }
        }

        let totalRemaining = grants.reduce(0) { $0 + $1.remaining }
        let totalGranted = grants.reduce(0) { $0 + $1.granted }

        // 最早到期且仍有余额的批次。
        let expiring = grants.compactMap { grant -> Date? in
            guard grant.remaining > 0, let expiration = grant.expiration else { return nil }
            return expiration
        }
        let nextExpiration = expiring.min()

        return BonusSummary(remaining: totalRemaining, total: totalGranted, nextExpiration: nextExpiration)
    }

    private static func parseBonusGrant(from grant: [String: Any]) -> BonusGrant {
        BonusGrant(
            granted: intValue(grant["requestCreditsGranted"]),
            remaining: intValue(grant["requestCreditsRemaining"]),
            expiration: (grant["expiration"] as? String).flatMap(parseDate))
    }

    // MARK: - 工具

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let num = value as? NSNumber { return num.intValue }
        if let text = value as? String, let int = Int(text) { return int }
        return 0
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes"].contains(normalized) { return true }
            if ["false", "0", "no"].contains(normalized) { return false }
        }
        return false
    }

    private static func graphQLErrorMessage(from value: Any) -> String? {
        if let message = value as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = value as? [String: Any], let message = dict["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: dateString)
    }
}
