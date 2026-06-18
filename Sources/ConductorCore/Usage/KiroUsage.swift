import Foundation

/// Kiro（AWS Kiro / `kiro-cli`）用量取数。**忠实转写自 CodexBar 的 `KiroStatusProbe`**。
///
/// 重要：CodexBar 的 Kiro provider 没有任何 token / 凭证文件 / cookie / HTTP 接口路径
/// （`grep kiro` 在 `ProviderTokenResolver.swift` 命中为空）。它唯一的数据来源是**子进程**：
/// 执行 `kiro-cli`（`whoami`、`chat --no-interactive /usage`、`chat --no-interactive /context`），
/// 再用正则解析终端输出。「凭证存在」等价于「`kiro-cli` 可执行文件可被找到」。
/// 因此这里 `hasCredentials()` 检查 PATH 上是否存在 `kiro-cli`，而不读环境变量或文件。
///
/// 富 `UsageSnapshot` 组装：
/// - 主额度（Credits，spec/plan 额度）→ primary 窗口，`used/limit*100`，`resetsAt` 取 CLI 给出的
///   `resets on …`（无周期概念，缺失则不带重置时刻）。同时把 credits 余额映射到 `providerCost`
///   （`used=已用 credits`、`limit=总额度`、`currencyCode "Credits"`、`period "Credits"`、`resetsAt`）。
/// - Bonus credits → secondary 窗口（按 `used/total*100`，`resetsAt` 取「expires in Nd」推算），缺失则 `secondary = nil`。
public enum KiroUsageError: LocalizedError, Sendable {
    case cliNotFound
    case notLoggedIn
    case cliFailed(String)
    case parseError(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .cliNotFound: L("未找到 kiro-cli，请从 https://kiro.dev 安装")
        case .notLoggedIn: L("未登录 Kiro，请先运行 `kiro-cli login`")
        case let .cliFailed(msg): L("kiro-cli 执行失败：%@", msg)
        case let .parseError(msg): L("解析 Kiro 用量失败：%@", msg)
        case .timeout: L("kiro-cli 执行超时")
        }
    }
}

public enum KiroUsageFetcher {
    /// 是否存在 Kiro 凭证。Kiro 走 CLI，本机「可用」等价于 PATH 上能找到 `kiro-cli`
    /// （CodexBar 用 `TTYCommandRunner.which("kiro-cli") != nil`）。便宜的本地检查，不弹任何授权框。
    public static func hasCredentials(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        which("kiro-cli", env: env) != nil
    }

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session _: URLSession = .shared) async throws -> UsageSnapshot
    {
        let account = try await ensureLoggedIn(env: env)
        let output = try await runUsageCommand(env: env)
        return try parse(output: output, planFallback: account.authMethod)
    }

    // MARK: - 凭证 / 可执行文件查找

    private struct AccountInfo {
        let authMethod: String?
        let email: String?
    }

    /// 等价于 CodexBar `KiroStatusProbe.ensureLoggedIn()`：跑 `kiro-cli whoami`。
    private static func ensureLoggedIn(env: [String: String]) async throws -> AccountInfo {
        let result = try await runCommand(arguments: ["whoami"], timeout: 5.0, env: env)
        return try validateWhoAmIOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            terminationStatus: result.terminationStatus)
    }

    private static func validateWhoAmIOutput(
        stdout: String,
        stderr: String,
        terminationStatus: Int32) throws -> AccountInfo
    {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = trimmedStderr.isEmpty ? trimmedStdout : trimmedStderr
        let lowered = combined.lowercased()

        if lowered.contains("not logged in") || lowered.contains("login required") {
            throw KiroUsageError.notLoggedIn
        }
        if terminationStatus != 0 {
            throw KiroUsageError.cliFailed(combined.isEmpty
                ? "Kiro CLI failed with status \(terminationStatus)."
                : combined)
        }
        if combined.isEmpty {
            throw KiroUsageError.cliFailed("Kiro CLI whoami returned no output.")
        }
        return parseWhoAmIOutput(combined)
    }

    private static func parseWhoAmIOutput(_ output: String) -> AccountInfo {
        let stripped = stripANSI(output)
        var authMethod: String?
        var email: String?
        for rawLine in stripped.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.localizedCaseInsensitiveContains("logged in with") {
                authMethod = line.replacingOccurrences(
                    of: #"(?i)^\s*logged in with\s+"#,
                    with: "",
                    options: [.regularExpression])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.localizedCaseInsensitiveContains("email:") {
                email = line.replacingOccurrences(
                    of: #"(?i)^\s*email:\s*"#,
                    with: "",
                    options: [.regularExpression])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if email == nil, !line.contains(" "), line.contains("@") {
                email = line
            }
        }
        return AccountInfo(authMethod: authMethod?.nilIfEmpty, email: email?.nilIfEmpty)
    }

    /// 在 PATH 上查找可执行文件（替代 CodexBar 的 `TTYCommandRunner.which`，纯 Foundation）。
    private static func which(_ tool: String, env: [String: String]) -> String? {
        let fm = FileManager.default
        let pathValue = env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        var dirs = pathValue.split(separator: ":").map(String.init)
        // 常见安装位置兜底（与 CodexBar 行为一致：尽量找到二进制）。
        dirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        let home = fm.homeDirectoryForCurrentUser.path
        dirs.append(contentsOf: ["\(home)/.local/bin", "\(home)/bin"])
        for dir in dirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 子进程

    private struct CLIResult {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
        let terminatedForIdle: Bool
    }

    /// 等价于 CodexBar `KiroStatusProbe.runUsageCommand()`：跑 `kiro-cli chat --no-interactive /usage`。
    private static func runUsageCommand(env: [String: String]) async throws -> String {
        let result = try await runCommand(
            arguments: ["chat", "--no-interactive", "/usage"],
            timeout: 20.0,
            idleTimeout: 10.0,
            env: env)
        let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedOutput = trimmedStderr.isEmpty ? trimmedStdout : trimmedStderr
        let combinedStripped = stripANSI(combinedOutput).lowercased()

        if combinedStripped.contains("not logged in")
            || combinedStripped.contains("login required")
            || combinedStripped.contains("failed to initialize auth portal")
            || combinedStripped.contains("kiro-cli login")
            || combinedStripped.contains("oauth error")
        {
            throw KiroUsageError.notLoggedIn
        }
        if result.terminatedForIdle, !isUsageOutputComplete(combinedOutput) {
            throw KiroUsageError.timeout
        }
        if !trimmedStdout.isEmpty { return result.stdout }
        if !trimmedStderr.isEmpty { return result.stderr }
        if result.terminationStatus != 0 {
            throw KiroUsageError.cliFailed(combinedOutput.isEmpty
                ? "Kiro CLI failed with status \(result.terminationStatus)."
                : combinedOutput)
        }
        return result.stdout
    }

    /// 等价于 CodexBar `KiroStatusProbe.runCommand`：起进程、跟踪空闲超时、读 stdout/stderr。
    private static func runCommand(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval = 5.0,
        env: [String: String]) async throws -> CLIResult
    {
        guard let binary = which("kiro-cli", env: env) else {
            throw KiroUsageError.cliNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        var childEnv = env
        childEnv["TERM"] = "xterm-256color"
        process.environment = childEnv

        // 线程安全的输出/活动跟踪（转写自 CodexBar 的 ActivityState）。
        final class ActivityState: @unchecked Sendable {
            private let lock = NSLock()
            private var _lastActivityAt = Date()
            private var _hasReceivedOutput = false
            private var _stdoutData = Data()
            private var _stderrData = Data()

            var lastActivityAt: Date {
                lock.lock(); defer { lock.unlock() }
                return _lastActivityAt
            }

            var hasReceivedOutput: Bool {
                lock.lock(); defer { lock.unlock() }
                return _hasReceivedOutput
            }

            func appendStdout(_ data: Data) {
                lock.lock(); defer { lock.unlock() }
                _stdoutData.append(data)
                _lastActivityAt = Date()
                _hasReceivedOutput = true
            }

            func appendStderr(_ data: Data) {
                lock.lock(); defer { lock.unlock() }
                _stderrData.append(data)
                _lastActivityAt = Date()
                _hasReceivedOutput = true
            }

            func getOutput() -> (stdout: Data, stderr: Data) {
                lock.lock(); defer { lock.unlock() }
                return (_stdoutData, _stderrData)
            }
        }

        let state = ActivityState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { state.appendStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { state.appendStderr(data) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                var didHitDeadline = false
                var didTerminateForIdle = false

                while process.isRunning {
                    if Date() >= deadline {
                        didHitDeadline = true
                        break
                    }
                    if state.hasReceivedOutput,
                       Date().timeIntervalSince(state.lastActivityAt) >= idleTimeout
                    {
                        didTerminateForIdle = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                    if didHitDeadline || !state.hasReceivedOutput {
                        continuation.resume(throwing: KiroUsageError.timeout)
                        return
                    }
                }

                let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                var output = state.getOutput()
                output.stdout.append(remainingStdout)
                output.stderr.append(remainingStderr)

                let stdoutOutput = String(data: output.stdout, encoding: .utf8) ?? ""
                let stderrOutput = String(data: output.stderr, encoding: .utf8) ?? ""
                continuation.resume(returning: CLIResult(
                    stdout: stdoutOutput,
                    stderr: stderrOutput,
                    terminationStatus: process.terminationStatus,
                    terminatedForIdle: didTerminateForIdle))
            }
        }
    }

    // MARK: - 解析（转写自 CodexBar `KiroStatusProbe.parse`）

    private static func parse(output: String, planFallback _: String?) throws -> UsageSnapshot {
        let stripped = stripANSI(output)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw KiroUsageError.parseError("Empty output from kiro-cli.")
        }

        let lowered = stripped.lowercased()
        if lowered.contains("could not retrieve usage information") {
            throw KiroUsageError.parseError("Kiro CLI could not retrieve usage information.")
        }
        if lowered.contains("not logged in")
            || lowered.contains("login required")
            || lowered.contains("failed to initialize auth portal")
            || lowered.contains("kiro-cli login")
            || lowered.contains("oauth error")
        {
            throw KiroUsageError.notLoggedIn
        }

        var matchedPercent = false
        var matchedCredits = false

        let parsedPlan = parsePlanName(from: stripped)
        let planName = parsedPlan.name
        let matchedNewFormat = parsedPlan.matchedNewFormat

        let isManagedPlan = lowered.contains("managed by admin")
            || lowered.contains("managed by organization")

        let resetsAt = parseResetDate(in: stripped)

        // 主额度百分比："████...█ X%"
        var creditsPercent = 0.0
        if let percentMatch = stripped.range(of: #"█+\s*(\d+)%"#, options: .regularExpression) {
            let percentStr = String(stripped[percentMatch])
            if let numMatch = percentStr.range(of: #"\d+"#, options: .regularExpression) {
                creditsPercent = Double(String(percentStr[numMatch])) ?? 0
                matchedPercent = true
            }
        }

        // 主额度 used/total："(X.XX of Y covered in plan)"
        var creditsUsed = 0.0
        var creditsTotal = 50.0 // 默认免费档
        if let creditsMatch = stripped.range(
            of: #"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered"#,
            options: .regularExpression)
        {
            let creditsStr = String(stripped[creditsMatch])
            let numbers = firstTwoNumbers(in: creditsStr)
            if numbers.count >= 2 {
                creditsUsed = numbers[0]
                creditsTotal = numbers[1]
                matchedCredits = true
            }
        }
        if !matchedPercent, matchedCredits, creditsTotal > 0 {
            creditsPercent = (creditsUsed / creditsTotal) * 100.0
        }

        let bonus = parseBonusCredits(in: stripped)

        // 受管计划（managed by admin/org）在新格式下可能无任何额度指标：只返回计划名。
        if matchedNewFormat, isManagedPlan, !matchedPercent, !matchedCredits {
            return makeSnapshot(
                planName: planName,
                creditsPercent: 0,
                creditsUsed: 0,
                creditsTotal: 0,
                resetsAt: nil,
                bonus: bonus)
        }

        // 至少要命中一个关键模式，否则视为格式变更。
        if !matchedPercent, !matchedCredits {
            throw KiroUsageError.parseError(
                "No recognizable usage patterns found. Kiro CLI output format may have changed.")
        }

        return makeSnapshot(
            planName: planName,
            creditsPercent: creditsPercent,
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            resetsAt: resetsAt,
            bonus: bonus)
    }

    /// 把 Kiro 主额度映射成 primary 窗口、Bonus credits 映射成 secondary 窗口，
    /// 并把 credits 余额（已用/总额度）补回到 `providerCost`。
    private static func makeSnapshot(
        planName: String,
        creditsPercent: Double,
        creditsUsed: Double,
        creditsTotal: Double,
        resetsAt: Date?,
        bonus: (used: Double?, total: Double?, expiryDays: Int?)) -> UsageSnapshot
    {
        let primary = RateWindow(
            title: L("额度"),
            usedPercent: creditsPercent,
            resetsAt: resetsAt)

        var secondary: RateWindow?
        if let bonusUsed = bonus.used, let bonusTotal = bonus.total, bonusTotal > 0 {
            let bonusPct = (bonusUsed / bonusTotal) * 100.0
            let reset = bonus.expiryDays.flatMap {
                Calendar.current.date(byAdding: .day, value: $0, to: Date())
            }
            secondary = RateWindow(
                title: L("奖励额度"),
                usedPercent: bonusPct,
                resetsAt: reset,
                resetDescription: bonus.expiryDays.map { L("%d 天后过期", $0) })
        }

        // credits 余额 → providerCost：used=已用 credits、limit=总额度（<=0 表示无上限）。
        var providerCost: ProviderCostSnapshot?
        if creditsTotal > 0 || creditsUsed > 0 {
            providerCost = ProviderCostSnapshot(
                used: creditsUsed,
                limit: creditsTotal,
                currencyCode: "Credits",
                period: L("额度"),
                resetsAt: resetsAt)
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            providerCost: providerCost,
            planName: displayPlanName(planName))
    }

    // MARK: - 解析辅助（转写自 CodexBar）

    private static func stripANSI(_ text: String) -> String {
        let pattern = #"\x1B\[[0-9;?]*[A-Za-z]|\x1B\].*?\x07"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func parsePlanName(from text: String) -> (name: String, matchedNewFormat: Bool) {
        var planName = "Kiro"
        var matchedNewFormat = false

        // 旧格式："| KIRO FREE"
        if let planMatch = text.range(of: #"\|\s*(KIRO\s+\w+)"#, options: .regularExpression) {
            let raw = String(text[planMatch]).replacingOccurrences(of: "|", with: "")
            planName = raw.trimmingCharacters(in: .whitespaces)
        }

        // kiro-cli 2.x："Estimated Usage | resets on 2026-06-01 | KIRO FREE"
        if let estimatedMatch = text.range(
            of: #"Estimated Usage\s*\|[^\n|]*\|\s*([A-Z][A-Z0-9 ]+)"#,
            options: .regularExpression)
        {
            let line = String(text[estimatedMatch])
            if let plan = line.split(separator: "|").last?.trimmingCharacters(in: .whitespacesAndNewlines),
               !plan.isEmpty
            {
                planName = plan
            }
        }

        // 新格式（kiro-cli 1.24+）："Plan: Q Developer Pro"
        if let newPlanMatch = text.range(of: #"Plan:\s*(.+)"#, options: .regularExpression) {
            let line = String(text[newPlanMatch])
            let planLine = line.replacingOccurrences(of: "Plan:", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let firstLine = planLine.split(separator: "\n").first {
                planName = String(firstLine).trimmingCharacters(in: .whitespaces)
                matchedNewFormat = true
            }
        }

        return (planName, matchedNewFormat)
    }

    private static func parseResetDate(in text: String) -> Date? {
        guard let resetMatch = text.range(
            of: #"resets on (\d{4}-\d{2}-\d{2}|\d{2}/\d{2})"#,
            options: .regularExpression)
        else { return nil }
        let resetStr = String(text[resetMatch])
        guard let dateRange = resetStr.range(
            of: #"\d{4}-\d{2}-\d{2}|\d{2}/\d{2}"#,
            options: .regularExpression)
        else { return nil }
        return parseResetDate(String(resetStr[dateRange]))
    }

    private static func parseBonusCredits(in text: String) -> (used: Double?, total: Double?, expiryDays: Int?) {
        var used: Double?
        var total: Double?
        var expiryDays: Int?
        if let bonusMatch = text.range(of: #"Bonus credits:\s*(\d+\.?\d*)/(\d+)"#, options: .regularExpression) {
            let bonusStr = String(text[bonusMatch])
            let numbers = firstTwoNumbers(in: bonusStr)
            if numbers.count >= 2 {
                used = numbers[0]
                total = numbers[1]
            }
        }
        if let expiryMatch = text.range(of: #"expires in (\d+) days?"#, options: .regularExpression) {
            let expiryStr = String(text[expiryMatch])
            if let numMatch = expiryStr.range(of: #"\d+"#, options: .regularExpression) {
                expiryDays = Int(String(expiryStr[numMatch]))
            }
        }
        return (used, total, expiryDays)
    }

    private static func parseResetDate(_ dateStr: String) -> Date? {
        if dateStr.contains("-") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Calendar.current.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: dateStr)
        }

        // MM/DD —— 取今年或明年
        let parts = dateStr.split(separator: "/")
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]) else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        var components = DateComponents()
        components.month = month
        components.day = day
        components.year = currentYear
        if let date = calendar.date(from: components), date > now { return date }
        components.year = currentYear + 1
        return calendar.date(from: components)
    }

    private static func displayPlanName(_ planName: String) -> String {
        let cleaned = planName
            .replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.localizedCaseInsensitiveContains("KIRO") else {
            return cleaned.isEmpty ? planName : cleaned
        }
        return cleaned
            .split(separator: " ")
            .map { word in
                if word.caseInsensitiveCompare("KIRO") == .orderedSame { return "Kiro" }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// 从字符串里按出现顺序抽取数字（替代 CodexBar 用到的 `matches(of:)` 正则，纯 NSRegularExpression）。
    private static func firstTwoNumbers(in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"\d+\.?\d*"#, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [Double] = []
        for match in regex.matches(in: text, options: [], range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            if let value = Double(String(text[range])) { result.append(value) }
            if result.count >= 2 { break }
        }
        return result
    }

    private static func isUsageOutputComplete(_ output: String) -> Bool {
        let stripped = stripANSI(output).lowercased()
        return stripped.contains("covered in plan")
            || stripped.contains("resets on")
            || stripped.contains("bonus credits")
            || stripped.contains("plan:")
            || stripped.contains("managed by admin")
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
