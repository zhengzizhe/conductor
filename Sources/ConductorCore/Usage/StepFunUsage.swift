import Foundation

/// StepFun（阶跃星辰）用量取数。忠实摘自 CodexBar `StepFun` provider，自足、不依赖浏览器 cookie：
/// 凭证为 **Oasis-Token**（token 类，env 优先）。优先读 `STEPFUN_TOKEN` 直接当令牌；
/// 否则用 `STEPFUN_USERNAME` + `STEPFUN_PASSWORD` 跑一遍登录流程
/// （访问首页拿 INGRESSCOOKIE → RegisterDevice 拿匿名 token → SignInByPassword 拿正式 token），
/// 拿到 token 后 POST `platform.stepfun.com/.../QueryStepPlanRateLimit`，
/// 解析五小时窗（primary/session）与周窗（secondary/weekly）的剩余额度（用 1-left 换算成已用百分比），
/// 再附带查一次套餐名（GetStepPlanStatus，失败则忽略）。账号级（与具体 CLI 无关）。
///
/// 环境变量：`STEPFUN_TOKEN`（Oasis-Token，优先），或 `STEPFUN_USERNAME` + `STEPFUN_PASSWORD`（登录流程）。
public enum StepFunUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingToken
    case server(Int)
    case invalidResponse
    case apiError(String)
    case loginFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            L("未找到 StepFun 凭证，请设置 STEPFUN_TOKEN，或 STEPFUN_USERNAME 与 STEPFUN_PASSWORD")
        case .missingToken: L("未找到 StepFun 令牌（Oasis-Token）")
        case let .server(code): L("StepFun 接口错误（%ld）", code)
        case .invalidResponse: L("StepFun 用量接口返回异常")
        case let .apiError(m): L("StepFun API 错误：%@", m)
        case let .loginFailed(m): L("StepFun 登录失败：%@", m)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum StepFunUsageFetcher {
    private static let platformURL = URL(string: "https://platform.stepfun.com")!
    private static let apiURL =
        URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")!
    private static let planStatusURL =
        URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus")!
    private static let registerDeviceURL =
        URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RegisterDevice")!
    private static let loginURL =
        URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/SignInByPassword")!
    private static let timeoutSeconds: TimeInterval = 15

    private static let webID = "c8a1002d2c457e758785a9979832217c7c0b884c"
    private static let appID = "10300"

    private static let baseHeaders: [String: String] = [
        "content-type": "application/json",
        "oasis-appid": appID,
        "oasis-platform": "web",
        "oasis-webid": webID,
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
    ]

    /// 是否配置了 StepFun 凭证（token 或 用户名+密码），用于在工具面板里把 StepFun 视作「可用」。
    public static func hasToken(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if token(env: env) != nil { return true }
        return username(env: env) != nil && password(env: env) != nil
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        let oasisToken: String
        if let direct = token(env: env) {
            oasisToken = normalize(direct)
        } else if let user = username(env: env), let pass = password(env: env) {
            oasisToken = try await login(username: user, password: pass, session: session)
        } else {
            throw StepFunUsageError.missingCredentials
        }
        guard !oasisToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StepFunUsageError.missingToken
        }
        return try await queryUsage(token: oasisToken, session: session)
    }

    // MARK: - 凭证（env）

    static func token(env: [String: String]) -> String? { clean(env["STEPFUN_TOKEN"]) }
    static func username(env: [String: String]) -> String? { clean(env["STEPFUN_USERNAME"]) }
    static func password(env: [String: String]) -> String? { clean(env["STEPFUN_PASSWORD"]) }

    static func clean(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// 从 cookie 头里抽出 Oasis-Token，否则原样返回（容许直接传裸 token）。
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("Oasis-Token=") {
            let parts = trimmed.components(separatedBy: "Oasis-Token=")
            if parts.count > 1 {
                return parts[1].components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? parts[1]
            }
        }
        return trimmed
    }

    // MARK: - 登录流程（用户名 + 密码 → Oasis-Token）

    private static func login(username: String, password: String, session: URLSession) async throws -> String {
        let ingressCookie = try await getIngressCookie(session: session)
        let anonToken = try await registerDevice(ingressCookie: ingressCookie, session: session)
        return try await signInByPassword(
            username: username,
            password: password,
            ingressCookie: ingressCookie,
            anonToken: anonToken,
            session: session)
    }

    /// 访问首页，从 Set-Cookie 头（或 cookie 存储）里抽出 INGRESSCOOKIE。
    private static func getIngressCookie(session: URLSession) async throws -> String {
        var request = URLRequest(url: platformURL)
        request.httpMethod = "GET"
        for (key, value) in baseHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.timeoutInterval = timeoutSeconds

        let http: HTTPURLResponse
        do {
            let (_, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw StepFunUsageError.invalidResponse }
            http = h
        } catch let e as StepFunUsageError {
            throw e
        } catch {
            throw StepFunUsageError.network(error.localizedDescription)
        }

        var ingressCookie = ""
        let setCookieHeaders = http.allHeaderFields.filter { ($0.key as? String)?.lowercased() == "set-cookie" }
        for (_, value) in setCookieHeaders {
            let cookieString = "\(value)"
            if cookieString.contains("INGRESSCOOKIE=") {
                let parts = cookieString.components(separatedBy: "INGRESSCOOKIE=")
                if parts.count > 1 {
                    let valuePart = parts[1].components(separatedBy: ";").first ?? ""
                    ingressCookie = valuePart.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if ingressCookie.isEmpty {
            let cookies = HTTPCookieStorage.shared.cookies(for: platformURL) ?? []
            for cookie in cookies where cookie.name == "INGRESSCOOKIE" {
                ingressCookie = cookie.value
                break
            }
        }
        guard !ingressCookie.isEmpty else {
            throw StepFunUsageError.loginFailed("Could not obtain INGRESSCOOKIE")
        }
        return ingressCookie
    }

    private static func registerDevice(ingressCookie: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: registerDeviceURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in baseHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("INGRESSCOOKIE=\(ingressCookie)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = timeoutSeconds

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw StepFunUsageError.invalidResponse }
            data = d; http = h
        } catch let e as StepFunUsageError {
            throw e
        } catch {
            throw StepFunUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else {
            throw StepFunUsageError.loginFailed("RegisterDevice HTTP \(http.statusCode)")
        }
        let decoded: AuthResponse
        do { decoded = try JSONDecoder().decode(AuthResponse.self, from: data) }
        catch { throw StepFunUsageError.loginFailed("RegisterDevice parse: \(error.localizedDescription)") }
        guard let access = decoded.accessToken?.raw, !access.isEmpty else {
            throw StepFunUsageError.loginFailed("No access token in RegisterDevice response")
        }
        return combinedToken(accessToken: access, refreshToken: decoded.refreshToken?.raw)
    }

    private static func signInByPassword(
        username: String,
        password: String,
        ingressCookie: String,
        anonToken: String,
        session: URLSession) async throws -> String
    {
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        for (key, value) in baseHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(
            "Oasis-Token=\(anonToken); Oasis-Webid=\(webID); INGRESSCOOKIE=\(ingressCookie)",
            forHTTPHeaderField: "Cookie")
        request.timeoutInterval = timeoutSeconds

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw StepFunUsageError.invalidResponse }
            data = d; http = h
        } catch let e as StepFunUsageError {
            throw e
        } catch {
            throw StepFunUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else {
            throw StepFunUsageError.loginFailed("SignInByPassword HTTP \(http.statusCode)")
        }
        let decoded: AuthResponse
        do { decoded = try JSONDecoder().decode(AuthResponse.self, from: data) }
        catch { throw StepFunUsageError.loginFailed("SignInByPassword parse: \(error.localizedDescription)") }
        guard let access = decoded.accessToken?.raw, !access.isEmpty else {
            throw StepFunUsageError.loginFailed("No access token in login response")
        }
        return combinedToken(accessToken: access, refreshToken: decoded.refreshToken?.raw)
    }

    private static func combinedToken(accessToken: String, refreshToken: String?) -> String {
        guard let refreshToken, !refreshToken.isEmpty else { return accessToken }
        return "\(accessToken)...\(refreshToken)"
    }

    // MARK: - 查询用量

    private static func queryUsage(token: String, session: URLSession) async throws -> CodexUsageSnapshot {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in baseHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webID)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = timeoutSeconds

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw StepFunUsageError.invalidResponse }
            data = d; http = h
        } catch let e as StepFunUsageError {
            throw e
        } catch {
            throw StepFunUsageError.network(error.localizedDescription)
        }
        guard http.statusCode == 200 else { throw StepFunUsageError.server(http.statusCode) }

        var snapshot = try parse(data)
        // 套餐名是锦上添花：失败就保留无套餐名的用量。
        if let planName = try? await queryPlanStatus(token: token, session: session) {
            snapshot = CodexUsageSnapshot(planType: planName, session: snapshot.session, weekly: snapshot.weekly)
        }
        return snapshot
    }

    private static func queryPlanStatus(token: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: planStatusURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in baseHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webID)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = timeoutSeconds

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let decoded = try? JSONDecoder().decode(PlanStatusResponse.self, from: data)
        return decoded?.planName
    }

    // MARK: - 解析

    /// API 返回的数字可能是 int(1) 或 float(0.997)，统一成 Double。
    private struct FlexibleNumber: Decodable {
        let value: Double
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = Double(i) }
            else if let d = try? c.decode(Double.self) { value = d }
            else { value = 0 }
        }
    }

    /// 重置时间戳可能是字符串 "1777528800" 或整数。
    private struct FlexibleTimestamp: Decodable {
        let value: Int64
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let parsed = Int64(s) { value = parsed }
            else if let i = try? c.decode(Int64.self) { value = i }
            else { value = 0 }
        }
    }

    private struct RateLimitResponse: Decodable {
        let status: Int?
        let code: Int?
        let message: String?
        let desc: String?
        let fiveHourUsageLeftRate: FlexibleNumber?
        let weeklyUsageLeftRate: FlexibleNumber?
        let fiveHourUsageResetTime: FlexibleTimestamp?
        let weeklyUsageResetTime: FlexibleTimestamp?

        enum CodingKeys: String, CodingKey {
            case status, code, message, desc
            case fiveHourUsageLeftRate = "five_hour_usage_left_rate"
            case weeklyUsageLeftRate = "weekly_usage_left_rate"
            case fiveHourUsageResetTime = "five_hour_usage_reset_time"
            case weeklyUsageResetTime = "weekly_usage_reset_time"
        }

        var isSuccess: Bool { status == 1 }
    }

    private struct PlanStatusResponse: Decodable {
        let status: Int?
        let subscription: Subscription?
        var planName: String? { subscription?.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
        struct Subscription: Decodable { let name: String? }
    }

    private struct AuthResponse: Decodable {
        let accessToken: TokenPair?
        let refreshToken: TokenPair?
        struct TokenPair: Decodable { let raw: String }
    }

    static func parse(_ data: Data) throws -> CodexUsageSnapshot {
        let decoded: RateLimitResponse
        do { decoded = try JSONDecoder().decode(RateLimitResponse.self, from: data) }
        catch { throw StepFunUsageError.invalidResponse }

        guard decoded.isSuccess else {
            let msg = [decoded.message, decoded.desc]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? decoded.code.map(String.init) ?? "unknown"
            throw StepFunUsageError.apiError(msg)
        }
        guard let fiveHourRate = decoded.fiveHourUsageLeftRate,
              let weeklyRate = decoded.weeklyUsageLeftRate,
              let fiveHourReset = decoded.fiveHourUsageResetTime,
              let weeklyReset = decoded.weeklyUsageResetTime
        else { throw StepFunUsageError.invalidResponse }

        // 剩余率 → 已用百分比；五小时窗 = primary/session，周窗 = secondary/weekly。
        let fiveHourUsed = max(0, min(100, Int(((1.0 - fiveHourRate.value) * 100).rounded())))
        let weeklyUsed = max(0, min(100, Int(((1.0 - weeklyRate.value) * 100).rounded())))

        let session = CodexUsageSnapshot.Window(
            usedPercent: fiveHourUsed,
            resetAt: Date(timeIntervalSince1970: TimeInterval(fiveHourReset.value)),
            windowSeconds: 5 * 3600)
        let weekly = CodexUsageSnapshot.Window(
            usedPercent: weeklyUsed,
            resetAt: Date(timeIntervalSince1970: TimeInterval(weeklyReset.value)),
            windowSeconds: 7 * 24 * 3600)

        return CodexUsageSnapshot(planType: nil, session: session, weekly: weekly)
    }
}
