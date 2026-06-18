import Foundation

public struct SkillManagerState: Codable, Equatable, Sendable {
    public var skills: [ManagedSkill]
    public var discovered: [DiscoveredSkillRecord]
    public var presets: [SkillPreset]
    public var projects: [SkillProject]
    public var projectTargets: [SkillProjectTargetRecord]
    public var disabledToolKeys: Set<String>
    public var customAdapters: [SkillToolAdapter]
    public var auditLog: [SkillAuditEntry]
    public var updatedAt: Date

    public init(skills: [ManagedSkill] = [],
                discovered: [DiscoveredSkillRecord] = [],
                presets: [SkillPreset] = [],
                projects: [SkillProject] = [],
                projectTargets: [SkillProjectTargetRecord] = [],
                disabledToolKeys: Set<String> = [],
                customAdapters: [SkillToolAdapter] = [],
                auditLog: [SkillAuditEntry] = [],
                updatedAt: Date = Date()) {
        self.skills = skills
        self.discovered = discovered
        self.presets = presets
        self.projects = projects
        self.projectTargets = projectTargets
        self.disabledToolKeys = disabledToolKeys
        self.customAdapters = customAdapters
        self.auditLog = auditLog
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case skills
        case discovered
        case presets
        case projects
        case projectTargets
        case disabledToolKeys
        case customAdapters
        case auditLog
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.skills = try container.decodeIfPresent([ManagedSkill].self, forKey: .skills) ?? []
        self.discovered = try container.decodeIfPresent([DiscoveredSkillRecord].self, forKey: .discovered) ?? []
        self.presets = try container.decodeIfPresent([SkillPreset].self, forKey: .presets) ?? []
        self.projects = try container.decodeIfPresent([SkillProject].self, forKey: .projects) ?? []
        self.projectTargets = try container.decodeIfPresent([SkillProjectTargetRecord].self, forKey: .projectTargets) ?? []
        self.disabledToolKeys = try container.decodeIfPresent(Set<String>.self, forKey: .disabledToolKeys) ?? []
        self.customAdapters = try container.decodeIfPresent([SkillToolAdapter].self, forKey: .customAdapters) ?? []
        self.auditLog = try container.decodeIfPresent([SkillAuditEntry].self, forKey: .auditLog) ?? []
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public final class SkillManagerStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private var state: SkillManagerState

    public init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.state = try Self.load(from: fileURL, fileManager: fileManager)
    }

    public func snapshot() -> SkillManagerState {
        state
    }

    public func skills() -> [ManagedSkill] {
        state.skills
    }

    public func discovered() -> [DiscoveredSkillRecord] {
        state.discovered
    }

    public func presets() -> [SkillPreset] {
        state.presets
    }

    public func projects() -> [SkillProject] {
        state.projects
    }

    public func projectTargets() -> [SkillProjectTargetRecord] {
        state.projectTargets
    }

    public func auditLog(limit: Int? = nil) -> [SkillAuditEntry] {
        let sorted = state.auditLog.sorted { $0.timestamp > $1.timestamp }
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    public func skill(id: String) -> ManagedSkill? {
        state.skills.first { $0.id == id }
    }

    public func preset(id: String) -> SkillPreset? {
        state.presets.first { $0.id == id }
    }

    public func project(id: String) -> SkillProject? {
        state.projects.first { $0.id == id }
    }

    public func upsertSkill(_ skill: ManagedSkill) throws {
        if let index = state.skills.firstIndex(where: { $0.id == skill.id }) {
            state.skills[index] = skill
        } else {
            state.skills.append(skill)
        }
        try save()
    }

    public func deleteSkill(id: String) throws {
        state.skills.removeAll { $0.id == id }
        state.discovered = state.discovered.map { record in
            var copy = record
            if copy.importedSkillID == id { copy.importedSkillID = nil }
            return copy
        }
        state.presets = state.presets.map { preset in
            var copy = preset
            copy.skills.removeAll { $0.skillID == id }
            return copy
        }
        state.projectTargets.removeAll { $0.skillID == id }
        try save()
    }

    public func upsertTarget(_ target: SkillTargetRecord) throws {
        guard let skillIndex = state.skills.firstIndex(where: { $0.id == target.skillID }) else {
            throw SkillManagerError.missingSkill(target.skillID)
        }
        if let targetIndex = state.skills[skillIndex].targets.firstIndex(where: { $0.tool == target.tool }) {
            state.skills[skillIndex].targets[targetIndex] = target
        } else {
            state.skills[skillIndex].targets.append(target)
        }
        state.skills[skillIndex].updatedAt = Date()
        try save()
    }

    public func deleteTarget(skillID: String, tool: String) throws {
        guard let skillIndex = state.skills.firstIndex(where: { $0.id == skillID }) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        state.skills[skillIndex].targets.removeAll { $0.tool == tool }
        state.skills[skillIndex].updatedAt = Date()
        try save()
    }

    public func replaceDiscovered(_ records: [DiscoveredSkillRecord]) throws {
        state.discovered = records
        state.updatedAt = Date()
        try save()
    }

    public func upsertPreset(_ preset: SkillPreset) throws {
        var copy = preset
        copy.updatedAt = Date()
        if let index = state.presets.firstIndex(where: { $0.id == preset.id }) {
            state.presets[index] = copy
        } else {
            state.presets.append(copy)
        }
        try save()
    }

    public func deletePreset(id: String) throws {
        state.presets.removeAll { $0.id == id }
        try save()
    }

    public func upsertProject(_ project: SkillProject) throws {
        var copy = project
        copy.updatedAt = Date()
        if let index = state.projects.firstIndex(where: { $0.id == project.id }) {
            state.projects[index] = copy
        } else {
            state.projects.append(copy)
        }
        try save()
    }

    public func deleteProject(id: String) throws {
        state.projects.removeAll { $0.id == id }
        state.projectTargets.removeAll { $0.projectID == id }
        try save()
    }

    public func upsertProjectTarget(_ target: SkillProjectTargetRecord) throws {
        guard state.projects.contains(where: { $0.id == target.projectID }) else {
            throw SkillManagerError.missingProject(target.projectID)
        }
        guard state.skills.contains(where: { $0.id == target.skillID }) else {
            throw SkillManagerError.missingSkill(target.skillID)
        }
        if let index = state.projectTargets.firstIndex(where: {
            $0.projectID == target.projectID && $0.skillID == target.skillID && $0.tool == target.tool
        }) {
            state.projectTargets[index] = target
        } else {
            state.projectTargets.append(target)
        }
        try save()
    }

    public func deleteProjectTarget(projectID: String, skillID: String, tool: String) throws {
        state.projectTargets.removeAll {
            $0.projectID == projectID && $0.skillID == skillID && $0.tool == tool
        }
        try save()
    }

    public func setDisabledToolKeys(_ keys: Set<String>) throws {
        state.disabledToolKeys = keys
        state.updatedAt = Date()
        try save()
    }

    public func setCustomAdapters(_ adapters: [SkillToolAdapter]) throws {
        state.customAdapters = adapters
        state.updatedAt = Date()
        try save()
    }

    public func appendAudit(_ entry: SkillAuditEntry) {
        state.auditLog.append(entry)
        if state.auditLog.count > 10_000 {
            state.auditLog.removeFirst(state.auditLog.count - 10_000)
        }
        try? save()
    }

    public func clearAuditLog() throws {
        state.auditLog.removeAll()
        try save()
    }

    private func save() throws {
        state.updatedAt = Date()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func load(from fileURL: URL,
                             fileManager: FileManager) throws -> SkillManagerState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SkillManagerState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(SkillManagerState.self, from: data)
    }
}
