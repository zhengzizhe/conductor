import Foundation

/// Tool adapter defaults and path semantics are adapted from
/// https://github.com/xingkongliang/skills-manager (MIT), commit b9c72b2.
public struct SkillToolCatalog: Sendable {
    public var adapters: [SkillToolAdapter]
    public var disabledToolKeys: Set<String>

    public init(adapters: [SkillToolAdapter] = Self.defaultAdapters,
                disabledToolKeys: Set<String> = []) {
        self.adapters = adapters
        self.disabledToolKeys = disabledToolKeys
    }

    public func adapter(for key: String) -> SkillToolAdapter? {
        adapters.first { $0.key == key }
    }

    public func toolInfos(fileManager: FileManager = .default) -> [SkillToolInfo] {
        adapters.map { adapter in
            SkillToolInfo(
                key: adapter.key,
                displayName: adapter.displayName,
                installed: adapter.isInstalled(fileManager: fileManager),
                enabled: !disabledToolKeys.contains(adapter.key),
                skillsDirectory: adapter.skillsDirectory().path,
                isCustom: adapter.isCustom,
                hasPathOverride: adapter.overrideSkillsDir != nil,
                projectRelativeSkillsDir: adapter.effectiveProjectRelativeSkillsDir,
                category: adapter.category)
        }
    }

    public static let defaultAdapters: [SkillToolAdapter] = [
        .init(key: "cursor", displayName: "Cursor",
              relativeSkillsDir: ".cursor/skills", relativeDetectDir: ".cursor"),
        .init(key: "claude_code", displayName: "Claude Code",
              relativeSkillsDir: ".claude/skills", relativeDetectDir: ".claude"),
        .init(key: "codex", displayName: "Codex",
              relativeSkillsDir: ".codex/skills", relativeDetectDir: ".codex",
              additionalScanDirs: [".agents/skills"]),
        .init(key: "grok", displayName: "Grok",
              relativeSkillsDir: ".grok/skills", relativeDetectDir: ".grok"),
        .init(key: "opencode", displayName: "OpenCode",
              relativeSkillsDir: ".config/opencode/skills", relativeDetectDir: ".config/opencode",
              projectRelativeSkillsDir: ".opencode/skills"),
        .init(key: "antigravity", displayName: "Antigravity",
              relativeSkillsDir: ".gemini/antigravity/skills", relativeDetectDir: ".gemini/antigravity"),
        .init(key: "amp", displayName: "Amp",
              relativeSkillsDir: ".config/agents/skills", relativeDetectDir: ".config/agents"),
        .init(key: "kilo_code", displayName: "Kilo Code",
              relativeSkillsDir: ".kilocode/skills", relativeDetectDir: ".kilocode"),
        .init(key: "roo_code", displayName: "Roo Code",
              relativeSkillsDir: ".roo/skills", relativeDetectDir: ".roo"),
        .init(key: "goose", displayName: "Goose",
              relativeSkillsDir: ".config/goose/skills", relativeDetectDir: ".config/goose"),
        .init(key: "gemini_cli", displayName: "Gemini CLI",
              relativeSkillsDir: ".gemini/skills", relativeDetectDir: ".gemini"),
        .init(key: "github_copilot", displayName: "GitHub Copilot",
              relativeSkillsDir: ".copilot/skills", relativeDetectDir: ".copilot",
              additionalScanDirs: [".agents/skills"]),
        .init(key: "openclaw", displayName: "OpenClaw",
              relativeSkillsDir: ".openclaw/skills", relativeDetectDir: ".openclaw",
              category: .lobster),
        .init(key: "droid", displayName: "Droid",
              relativeSkillsDir: ".factory/skills", relativeDetectDir: ".factory"),
        .init(key: "windsurf", displayName: "Windsurf",
              relativeSkillsDir: ".codeium/windsurf/skills", relativeDetectDir: ".codeium/windsurf"),
        .init(key: "trae", displayName: "TRAE IDE",
              relativeSkillsDir: ".trae/skills", relativeDetectDir: ".trae"),
        .init(key: "cline", displayName: "Cline",
              relativeSkillsDir: ".agents/skills", relativeDetectDir: ".cline"),
        .init(key: "deepagents", displayName: "Deep Agents",
              relativeSkillsDir: ".deepagents/agent/skills", relativeDetectDir: ".deepagents"),
        .init(key: "firebender", displayName: "Firebender",
              relativeSkillsDir: ".firebender/skills", relativeDetectDir: ".firebender"),
        .init(key: "kimi", displayName: "Kimi Code CLI",
              relativeSkillsDir: ".config/agents/skills", relativeDetectDir: ".kimi"),
        .init(key: "replit", displayName: "Replit",
              relativeSkillsDir: ".config/agents/skills", relativeDetectDir: ".replit"),
        .init(key: "warp", displayName: "Warp",
              relativeSkillsDir: ".agents/skills", relativeDetectDir: ".warp"),
        .init(key: "augment", displayName: "Augment",
              relativeSkillsDir: ".augment/skills", relativeDetectDir: ".augment"),
        .init(key: "bob", displayName: "IBM Bob",
              relativeSkillsDir: ".bob/skills", relativeDetectDir: ".bob"),
        .init(key: "codebuddy", displayName: "CodeBuddy",
              relativeSkillsDir: ".codebuddy/skills", relativeDetectDir: ".codebuddy"),
        .init(key: "command_code", displayName: "Command Code",
              relativeSkillsDir: ".commandcode/skills", relativeDetectDir: ".commandcode"),
        .init(key: "continue", displayName: "Continue",
              relativeSkillsDir: ".continue/skills", relativeDetectDir: ".continue"),
        .init(key: "cortex", displayName: "Cortex Code",
              relativeSkillsDir: ".snowflake/cortex/skills", relativeDetectDir: ".snowflake/cortex"),
        .init(key: "crush", displayName: "Crush",
              relativeSkillsDir: ".config/crush/skills", relativeDetectDir: ".config/crush"),
        .init(key: "iflow", displayName: "iFlow CLI",
              relativeSkillsDir: ".iflow/skills", relativeDetectDir: ".iflow"),
        .init(key: "junie", displayName: "Junie",
              relativeSkillsDir: ".junie/skills", relativeDetectDir: ".junie"),
        .init(key: "kiro", displayName: "Kiro CLI",
              relativeSkillsDir: ".kiro/skills", relativeDetectDir: ".kiro"),
        .init(key: "kode", displayName: "Kode",
              relativeSkillsDir: ".kode/skills", relativeDetectDir: ".kode"),
        .init(key: "mcpjam", displayName: "MCPJam",
              relativeSkillsDir: ".mcpjam/skills", relativeDetectDir: ".mcpjam"),
        .init(key: "mistral_vibe", displayName: "Mistral Vibe",
              relativeSkillsDir: ".vibe/skills", relativeDetectDir: ".vibe"),
        .init(key: "mux", displayName: "Mux",
              relativeSkillsDir: ".mux/skills", relativeDetectDir: ".mux"),
        .init(key: "neovate", displayName: "Neovate",
              relativeSkillsDir: ".neovate/skills", relativeDetectDir: ".neovate"),
        .init(key: "openhands", displayName: "OpenHands",
              relativeSkillsDir: ".openhands/skills", relativeDetectDir: ".openhands"),
        .init(key: "pi", displayName: "Pi",
              relativeSkillsDir: ".pi/skills", relativeDetectDir: ".pi"),
        .init(key: "pochi", displayName: "Pochi",
              relativeSkillsDir: ".pochi/skills", relativeDetectDir: ".pochi"),
        .init(key: "qoder", displayName: "Qoder",
              relativeSkillsDir: ".qoder/skills", relativeDetectDir: ".qoder"),
        .init(key: "qwen_code", displayName: "Qwen Code",
              relativeSkillsDir: ".qwen/skills", relativeDetectDir: ".qwen"),
        .init(key: "trae_cn", displayName: "TRAE CN",
              relativeSkillsDir: ".trae-cn/skills", relativeDetectDir: ".trae-cn"),
        .init(key: "zencoder", displayName: "Zencoder",
              relativeSkillsDir: ".zencoder/skills", relativeDetectDir: ".zencoder"),
        .init(key: "adal", displayName: "AdaL",
              relativeSkillsDir: ".adal/skills", relativeDetectDir: ".adal"),
        .init(key: "hermes", displayName: "Hermes Agent",
              relativeSkillsDir: ".config/hermes/skills", relativeDetectDir: ".config/hermes",
              recursiveScan: true, category: .lobster),
        .init(key: "qclaw", displayName: "QClaw",
              relativeSkillsDir: ".qclaw/skills", relativeDetectDir: ".qclaw",
              category: .lobster),
        .init(key: "easyclaw", displayName: "EasyClaw",
              relativeSkillsDir: ".easyclaw/skills", relativeDetectDir: ".easyclaw",
              category: .lobster),
        .init(key: "autoclaw", displayName: "AutoClaw",
              relativeSkillsDir: ".autoclaw/skills", relativeDetectDir: ".autoclaw",
              category: .lobster),
        .init(key: "workbuddy", displayName: "WorkBuddy",
              relativeSkillsDir: ".workbuddy/skills", relativeDetectDir: ".workbuddy")
    ]
}

public extension SkillToolAdapter {
    var effectiveProjectRelativeSkillsDir: String? {
        projectRelativeSkillsDir ?? relativeSkillsDir
    }

    func skillsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let overrideSkillsDir, !overrideSkillsDir.isEmpty {
            return URL(fileURLWithPath: (overrideSkillsDir as NSString).expandingTildeInPath)
        }
        return selectExistingOrDefault(candidatePaths(for: relativeSkillsDir, home: home))
    }

    func additionalExistingScanDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        var out: [URL] = []
        for relative in additionalScanDirs {
            for candidate in candidatePaths(for: relative, home: home)
            where fileManager.fileExists(atPath: candidate.path) && !out.contains(candidate) {
                out.append(candidate)
            }
        }
        return out
    }

    func allScanDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        var out = [skillsDirectory(home: home)]
        for candidate in additionalExistingScanDirectories(home: home, fileManager: fileManager)
        where !out.contains(candidate) {
            out.append(candidate)
        }
        return out
    }

    func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     fileManager: FileManager = .default) -> Bool {
        if isCustom || overrideSkillsDir != nil { return true }
        return candidatePaths(for: relativeDetectDir, home: home).contains {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    private func candidatePaths(for relative: String, home: URL) -> [URL] {
        var candidates = [home.appendingPathComponent(relative)]
        if relative.hasPrefix(".config/") {
            let suffix = String(relative.dropFirst(".config/".count))
            let configDir = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first
            if let configDir {
                let configCandidate = configDir.appendingPathComponent(suffix)
                if !candidates.contains(configCandidate) { candidates.append(configCandidate) }
            }
        }
        return candidates
    }

    private func selectExistingOrDefault(_ paths: [URL]) -> URL {
        paths.first { FileManager.default.fileExists(atPath: $0.path) } ?? paths[0]
    }
}
