import Foundation
import SweetCookieKit

/// Ollama（ollama.com Cloud）用量取数。忠实摘自 CodexBar `Ollama` provider 的浏览器 cookie 路径
/// （用 SweetCookieKit）：从浏览器读 ollama.com 的登录 cookie → `GET https://ollama.com/settings`
/// → 在返回的 HTML 里抓「Session usage / Hourly usage」与「Weekly usage」两个用量块的百分比与重置时刻。
///
/// 为什么走 cookie 而不是 token：CodexBar 里 Ollama 的 token(env) 路径（`OLLAMA_API_KEY` / `OLLAMA_KEY`
/// → `Bearer` → `GET https://ollama.com/api/tags`）只回模型列表，能拿到的只有「已安装模型数」，
/// 没有任何额度/百分比/重置时间，无法填 `Window(usedPercent:resetAt:windowSeconds:)`。真正的会话/周用量
/// 只在 `/settings` 页面 HTML 里，故这里转写 cookie 路径。
///
/// 解析照搬 CodexBar `OllamaUsageParser`：百分比优先匹配 `N% used`，回退 `width: N%`；重置时刻取
/// `data-time="<ISO8601>"`。session 窗固定 5 小时（300 分钟），weekly 窗固定 7 天。无百分比则该窗为 nil。
/// 套餐名取「Cloud Usage」后的 `<span>` 文本，账号邮箱取 `id="header-email"`（这里只用套餐名作 planType）。
///
/// 注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；Safari 需要「完全磁盘访问」。
/// 照搬自 CodexBar，本机无登录态无法实跑验证。
public enum OllamaUsageError: LocalizedError, Sendable {
    case noSession
    case unauthorized
    case notLoggedIn
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 Ollama 登录态，请在浏览器登录 ollama.com（Safari 需开启完全磁盘访问）")
        case .unauthorized: L("Ollama 登录态已失效，请重新登录 ollama.com")
        case .notLoggedIn: L("尚未登录 Ollama，请在浏览器登录 ollama.com/settings")
        case let .server(c): L("Ollama 接口错误（%ld）", c)
        case .invalidResponse: L("Ollama 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum OllamaUsageFetcher {
    private static let settingsURL = URL(string: "https://ollama.com/settings")!
    // 照搬 CodexBar：ollama.com / www.ollama.com 两域。
    private static let cookieDomains = ["ollama.com", "www.ollama.com"]
    // 照搬 CodexBar 的已知会话 cookie 名（含 next-auth 的分块 `<name>.0`/`.1`）。
    private static let sessionCookieNames: Set<String> = [
        "session", "__Secure-session", "ollama_session", "__Host-ollama_session",
        "__Secure-next-auth.session-token", "next-auth.session-token",
    ]

    private static func isRecognizedSessionCookieName(_ name: String) -> Bool {
        if sessionCookieNames.contains(name) { return true }
        return name.hasPrefix("__Secure-next-auth.session-token.") || name.hasPrefix("next-auth.session-token.")
    }

    /// 是否能从浏览器拿到 Ollama 登录 cookie（要求至少含一个已知会话 cookie）。
    /// 注意：会触发一次浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 ollama 域 cookie，要求含已知会话 cookie；拼成 Cookie 头返回。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "ollama", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "ollama", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            guard cookies.contains(where: { isRecognizedSessionCookieName($0.name) }) else { continue }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }

    public static func fetch(session: URLSession = .shared) async throws -> CodexUsageSnapshot {
        guard let header = cookieHeader() else { throw OllamaUsageError.noSession }

        var request = URLRequest(url: settingsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("https://ollama.com", forHTTPHeaderField: "origin")
        request.setValue(settingsURL.absoluteString, forHTTPHeaderField: "referer")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw OllamaUsageError.invalidResponse }
            data = d; http = h
        } catch let e as OllamaUsageError {
            throw e
        } catch {
            throw OllamaUsageError.network(error.localizedDescription)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw OllamaUsageError.unauthorized }
        guard http.statusCode == 200 else { throw OllamaUsageError.server(http.statusCode) }

        let html = String(data: data, encoding: .utf8) ?? ""
        return try parse(html: html, now: Date())
    }

    // MARK: - 解析（照搬 CodexBar OllamaUsageParser）

    private static let primaryUsageLabels = ["Session usage", "Hourly usage"]
    private static let allUsageLabels = ["Session usage", "Hourly usage", "Weekly usage"]

    private struct UsageBlock {
        let usedPercent: Double
        let resetsAt: Date?
        let windowSeconds: Int?
    }

    static func parse(html: String, now: Date) throws -> CodexUsageSnapshot {
        let plan = parsePlanName(html)
        // session = 「Session usage」或「Hourly usage」（取先命中者）；weekly = 「Weekly usage」。
        let session = parseUsageBlock(labels: primaryUsageLabels, html: html)
        let weekly = parseUsageBlock(label: "Weekly usage", html: html)

        if session == nil, weekly == nil {
            if looksSignedOut(html) { throw OllamaUsageError.notLoggedIn }
            throw OllamaUsageError.invalidResponse
        }

        return CodexUsageSnapshot(
            planType: plan,
            session: window(from: session),
            weekly: window(from: weekly))
    }

    /// 把一个用量块换算成 `Window`：无 reset 时回退 now + 窗口时长（session 5 小时 / weekly 7 天）。
    private static func window(from block: UsageBlock?) -> CodexUsageSnapshot.Window? {
        guard let block else { return nil }
        let secs = block.windowSeconds ?? 0
        let used = max(0, min(100, Int(block.usedPercent.rounded())))
        let fallback = TimeInterval(secs > 0 ? secs : 30 * 24 * 3600)
        let now = Date()
        return CodexUsageSnapshot.Window(
            usedPercent: used,
            resetAt: block.resetsAt ?? now.addingTimeInterval(fallback),
            windowSeconds: secs)
    }

    private static func parsePlanName(_ html: String) -> String? {
        let pattern = #"Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>"#
        guard let raw = firstCapture(in: html, pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseUsageBlock(labels: [String], html: String) -> UsageBlock? {
        for label in labels {
            if let parsed = parseUsageBlock(label: label, html: html) { return parsed }
        }
        return nil
    }

    private static func parseUsageBlock(label: String, html: String) -> UsageBlock? {
        guard let labelRange = html.range(of: label) else { return nil }
        let tail = String(html[labelRange.upperBound...])
        let window = usageBlockWindow(after: label, in: tail)

        guard let usedPercent = parsePercent(in: window) else { return nil }
        let resetsAt = parseISODate(in: window)
        // 照搬 CodexBar：只有「Session usage」标 5 小时窗；其余（含 Hourly / Weekly）由调用方按需补。
        let windowSeconds = label == "Session usage" ? 5 * 60 * 60 : (label == "Weekly usage" ? 7 * 24 * 60 * 60 : nil)
        return UsageBlock(usedPercent: usedPercent, resetsAt: resetsAt, windowSeconds: windowSeconds)
    }

    /// 截取某用量标签之后、到下一个用量标签之前（或 4000 字）的 HTML 片段，避免跨块误匹配。
    private static func usageBlockWindow(after label: String, in tail: String) -> String {
        let maxLength = 4000
        let boundary = allUsageLabels
            .filter { $0 != label }
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min()
        let bounded = boundary.map { String(tail[..<$0]) } ?? String(tail.prefix(maxLength))
        return String(bounded.prefix(maxLength))
    }

    private static func parsePercent(in text: String) -> Double? {
        let usedPattern = #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
        if let raw = firstCapture(in: text, pattern: usedPattern, options: [.caseInsensitive]) {
            return Double(raw)
        }
        let widthPattern = #"width:\s*([0-9]+(?:\.[0-9]+)?)%"#
        if let raw = firstCapture(in: text, pattern: widthPattern, options: [.caseInsensitive]) {
            return Double(raw)
        }
        return nil
    }

    private static func parseISODate(in text: String) -> Date? {
        let pattern = #"data-time=\"([^\"]+)\""#
        guard let raw = firstCapture(in: text, pattern: pattern, options: []) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }

    private static func firstCapture(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options) -> String?
    {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    /// 照搬 CodexBar：HTML 看着像登录页（有表单 + 邮箱/密码字段或登录路由）即判为「未登录」。
    private static func looksSignedOut(_ html: String) -> Bool {
        let lower = html.lowercased()
        let hasSignInHeading = lower.contains("sign in to ollama") || lower.contains("log in to ollama")
        let hasAuthRoute = lower.contains("/api/auth/signin") || lower.contains("/auth/signin")
        let hasLoginRoute = lower.contains("action=\"/login\"") || lower.contains("action='/login'")
            || lower.contains("href=\"/login\"") || lower.contains("href='/login'")
            || lower.contains("action=\"/signin\"") || lower.contains("action='/signin'")
            || lower.contains("href=\"/signin\"") || lower.contains("href='/signin'")
        let hasPasswordField = lower.contains("type=\"password\"") || lower.contains("type='password'")
            || lower.contains("name=\"password\"") || lower.contains("name='password'")
        let hasEmailField = lower.contains("type=\"email\"") || lower.contains("type='email'")
            || lower.contains("name=\"email\"") || lower.contains("name='email'")
        let hasAuthForm = lower.contains("<form")
        let hasAuthEndpoint = hasAuthRoute || hasLoginRoute

        if hasSignInHeading, hasAuthForm, hasEmailField || hasPasswordField || hasAuthEndpoint { return true }
        if hasAuthForm, hasAuthEndpoint { return true }
        if hasAuthForm, hasPasswordField, hasEmailField { return true }
        return false
    }
}
