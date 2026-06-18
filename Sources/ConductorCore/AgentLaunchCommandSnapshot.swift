import Foundation

public struct AgentLaunchCommandSnapshot: Codable, Equatable, Sendable {
    public var agent: String
    public var argv: [String]
    public var cwd: String?
    public var capturedAt: Date

    public init(agent: String, argv: [String], cwd: String? = nil, capturedAt: Date = Date()) {
        self.agent = agent
        self.argv = argv
        self.cwd = cwd
        self.capturedAt = capturedAt
    }

    public var shellCommand: String {
        argv.map(ShellCommandQuoting.token).joined(separator: " ")
    }
}

public enum AgentLaunchCommandSanitizer {
    private static let flagsWithValues: Set<String> = [
        "-c", "-m",
        "--approval-policy", "--config", "--config-file", "--cwd", "--directory", "--dir",
        "--model", "--profile", "--provider", "--sandbox", "--sandbox-mode",
        "--system-prompt-file", "--workdir", "--workspace",
    ]

    private static let booleanFlags: Set<String> = [
        "--dangerously-bypass-approvals-and-sandbox",
        "--experimental", "--full-auto", "--no-sandbox", "--quiet", "--verbose",
    ]

    private static let dropFlagsWithValues: Set<String> = [
        "-p", "--api-key", "--auth", "--authorization", "--cookie", "--key",
        "--password", "--prompt", "--resume", "--resume-id", "--restore",
        "--secret", "--session", "--session-id", "--sessionId", "--token",
    ]

    public static func snapshot(
        agent: String,
        command: String,
        cwd: String?,
        capturedAt: Date = Date()
    ) -> AgentLaunchCommandSnapshot? {
        let words = ShellWords.split(command)
        guard !words.isEmpty else { return nil }
        let executable = defaultExecutable(for: agent, fallback: words[0])
        let sanitized = [executable] + preservedArguments(Array(words.dropFirst()))
        return AgentLaunchCommandSnapshot(agent: agent, argv: sanitized, cwd: cwd, capturedAt: capturedAt)
    }

    public static func resumeCommand(
        agent: String,
        sessionID: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> String? {
        guard let argv = resumeArgv(agent: agent, sessionID: sessionID, launchCommand: launchCommand) else {
            return nil
        }
        return argv.map(ShellCommandQuoting.token).joined(separator: " ")
    }

    public static func resumeArgv(
        agent: String,
        sessionID: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        let executable = launchCommand?.argv.first ?? defaultExecutable(for: agent, fallback: agent)
        let preserved = launchCommand.map { Array($0.argv.dropFirst()) } ?? []
        let id = sessionID
        switch agent {
        case "claude": return [executable] + preserved + ["--resume", id]
        case "codex": return [executable] + preserved + ["resume", id]
        case "gemini": return [executable] + preserved + ["--resume", id]
        case "cursor": return [executable] + preserved + ["--resume", id]
        case "copilot": return [executable] + preserved + ["--resume", id]
        case "grok": return [executable] + preserved + ["-r", id]
        case "opencode": return [executable] + preserved + ["--session", id]
        case "amp": return [executable] + preserved + ["threads", "continue", id]
        default: return nil
        }
    }

    private static func defaultExecutable(for agent: String, fallback: String) -> String {
        switch agent {
        case "cursor": return "cursor-agent"
        default: return fallback.isEmpty ? agent : fallback
        }
    }

    private static func preservedArguments(_ args: [String]) -> [String] {
        var output: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if shouldStopAtPositional(arg) { break }
            let name = optionName(arg)
            if isSensitive(name) || dropFlagsWithValues.contains(name) {
                if optionTakesSeparateValue(arg, name: name), index + 1 < args.count { index += 2 } else { index += 1 }
                continue
            }
            if flagsWithValues.contains(name) {
                if arg.contains("=") {
                    if !isSensitive(arg) { output.append(arg) }
                    index += 1
                } else if index + 1 < args.count, !isSensitive(args[index + 1]) {
                    output.append(arg)
                    output.append(args[index + 1])
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if booleanFlags.contains(arg) || booleanFlags.contains(name) || allowedPrefixedOption(arg) {
                output.append(arg)
            }
            index += 1
        }
        return output
    }

    private static func shouldStopAtPositional(_ arg: String) -> Bool {
        if arg == "--" { return true }
        return !arg.hasPrefix("-")
    }

    private static func optionName(_ arg: String) -> String {
        guard let equals = arg.firstIndex(of: "=") else { return arg }
        return String(arg[..<equals])
    }

    private static func optionTakesSeparateValue(_ arg: String, name: String) -> Bool {
        !arg.contains("=") && (flagsWithValues.contains(name) || dropFlagsWithValues.contains(name))
    }

    private static func allowedPrefixedOption(_ arg: String) -> Bool {
        let allowedPrefixes = [
            "--approval-policy=", "--config=", "--config-file=", "--cwd=", "--directory=",
            "--dir=", "--model=", "--profile=", "--provider=", "--sandbox=", "--sandbox-mode=",
            "--workdir=", "--workspace=",
        ]
        return allowedPrefixes.contains { arg.hasPrefix($0) } && !isSensitive(arg)
    }

    private static func isSensitive(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("api-key")
            || lower.contains("apikey")
            || lower.contains("auth")
            || lower.contains("cookie")
            || lower.contains("credential")
            || lower.contains("password")
            || lower.contains("secret")
            || lower.contains("token")
    }
}
