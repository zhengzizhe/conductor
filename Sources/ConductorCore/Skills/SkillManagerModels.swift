import Foundation

public struct SkillsShSkill: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var skillID: String
    public var name: String
    public var source: String
    public var installs: UInt64

    public init(id: String, skillID: String, name: String, source: String, installs: UInt64) {
        self.id = id
        self.skillID = skillID
        self.name = name
        self.source = source
        self.installs = installs
    }
}

/// A normalized AI-agent tool target that can receive skills.
public struct SkillToolAdapter: Codable, Equatable, Sendable, Identifiable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case coding
        case lobster
    }

    public var id: String { key }
    public var key: String
    public var displayName: String
    public var relativeSkillsDir: String
    public var relativeDetectDir: String
    public var additionalScanDirs: [String]
    public var overrideSkillsDir: String?
    public var bookmarkData: Data?
    public var isCustom: Bool
    public var recursiveScan: Bool
    public var projectRelativeSkillsDir: String?
    public var category: Category

    public init(
        key: String,
        displayName: String,
        relativeSkillsDir: String,
        relativeDetectDir: String,
        additionalScanDirs: [String] = [],
        overrideSkillsDir: String? = nil,
        bookmarkData: Data? = nil,
        isCustom: Bool = false,
        recursiveScan: Bool = false,
        projectRelativeSkillsDir: String? = nil,
        category: Category = .coding
    ) {
        self.key = key
        self.displayName = displayName
        self.relativeSkillsDir = relativeSkillsDir
        self.relativeDetectDir = relativeDetectDir
        self.additionalScanDirs = additionalScanDirs
        self.overrideSkillsDir = overrideSkillsDir
        self.bookmarkData = bookmarkData
        self.isCustom = isCustom
        self.recursiveScan = recursiveScan
        self.projectRelativeSkillsDir = projectRelativeSkillsDir
        self.category = category
    }
}

public struct SkillToolInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var displayName: String
    public var installed: Bool
    public var enabled: Bool
    public var skillsDirectory: String
    public var isCustom: Bool
    public var hasPathOverride: Bool
    public var projectRelativeSkillsDir: String?
    public var category: SkillToolAdapter.Category
}

public struct ManagedSkill: Codable, Equatable, Sendable, Identifiable {
    public enum SourceType: String, Codable, Sendable {
        case local
        case git
        case skillssh
        case imported
    }

    public var id: String
    public var name: String
    public var description: String?
    public var sourceType: SourceType
    public var sourceRef: String?
    public var sourceSubpath: String?
    public var sourceBranch: String?
    public var sourceRevision: String?
    public var remoteRevision: String?
    public var sourceBookmarkData: Data?
    public var centralPath: String
    public var contentHash: String?
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var status: String
    public var updateStatus: String
    public var lastCheckedAt: Date?
    public var lastCheckError: String?
    public var targets: [SkillTargetRecord]
    public var tags: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String?,
        sourceType: SourceType,
        sourceRef: String?,
        sourceSubpath: String? = nil,
        sourceBranch: String? = nil,
        sourceRevision: String? = nil,
        remoteRevision: String? = nil,
        sourceBookmarkData: Data? = nil,
        centralPath: String,
        contentHash: String?,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: String = "ok",
        updateStatus: String = "unknown",
        lastCheckedAt: Date? = nil,
        lastCheckError: String? = nil,
        targets: [SkillTargetRecord] = [],
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sourceType = sourceType
        self.sourceRef = sourceRef
        self.sourceSubpath = sourceSubpath
        self.sourceBranch = sourceBranch
        self.sourceRevision = sourceRevision
        self.remoteRevision = remoteRevision
        self.sourceBookmarkData = sourceBookmarkData
        self.centralPath = centralPath
        self.contentHash = contentHash
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.updateStatus = updateStatus
        self.lastCheckedAt = lastCheckedAt
        self.lastCheckError = lastCheckError
        self.targets = targets
        self.tags = tags
    }
}

public struct SkillTargetRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        case symlink
        case copy
    }

    public var id: String
    public var skillID: String
    public var tool: String
    public var targetPath: String
    public var mode: Mode
    public var status: String
    public var syncedAt: Date?
    public var lastError: String?
    public var sourceHash: String?

    public init(
        id: String = UUID().uuidString,
        skillID: String,
        tool: String,
        targetPath: String,
        mode: Mode,
        status: String = "ok",
        syncedAt: Date? = Date(),
        lastError: String? = nil,
        sourceHash: String? = nil
    ) {
        self.id = id
        self.skillID = skillID
        self.tool = tool
        self.targetPath = targetPath
        self.mode = mode
        self.status = status
        self.syncedAt = syncedAt
        self.lastError = lastError
        self.sourceHash = sourceHash
    }
}

public struct DiscoveredSkillRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tool: String
    public var foundPath: String
    public var nameGuess: String?
    public var fingerprint: String?
    public var foundAt: Date
    public var importedSkillID: String?
    public var bookmarkData: Data?

    public init(
        id: String = UUID().uuidString,
        tool: String,
        foundPath: String,
        nameGuess: String?,
        fingerprint: String?,
        foundAt: Date = Date(),
        importedSkillID: String? = nil,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.tool = tool
        self.foundPath = foundPath
        self.nameGuess = nameGuess
        self.fingerprint = fingerprint
        self.foundAt = foundAt
        self.importedSkillID = importedSkillID
        self.bookmarkData = bookmarkData
    }
}

public struct DiscoveredSkillGroup: Codable, Equatable, Sendable, Identifiable {
    public struct Location: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var tool: String
        public var foundPath: String
    }

    public var id: String { fingerprint ?? name.lowercased() }
    public var name: String
    public var fingerprint: String?
    public var locations: [Location]
    public var imported: Bool
    public var foundAt: Date
}

public struct SkillScanResult: Codable, Equatable, Sendable {
    public var toolsScanned: Int
    public var skillsFound: Int
    public var groups: [DiscoveredSkillGroup]
}

public struct SkillDocument: Codable, Equatable, Sendable {
    public var skillID: String
    public var filename: String
    public var content: String
    public var centralPath: String
    public var truncated: Bool

    public init(skillID: String,
                filename: String,
                content: String,
                centralPath: String,
                truncated: Bool = false) {
        self.skillID = skillID
        self.filename = filename
        self.content = content
        self.centralPath = centralPath
        self.truncated = truncated
    }
}

public struct SkillFileInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String
    public var size: Int64
    public var modifiedAt: Date?

    public init(relativePath: String, size: Int64, modifiedAt: Date? = nil) {
        self.relativePath = relativePath
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct SkillSourceDiff: Codable, Equatable, Sendable {
    public var skillID: String
    public var sourcePath: String
    public var entries: [SkillSourceDiffEntry]

    public init(skillID: String, sourcePath: String, entries: [SkillSourceDiffEntry]) {
        self.skillID = skillID
        self.sourcePath = sourcePath
        self.entries = entries
    }
}

public struct SkillSourceDiffEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String
    public var status: String
    public var originalKind: String
    public var updatedKind: String
    public var originalContent: String?
    public var updatedContent: String?

    public init(relativePath: String,
                status: String,
                originalKind: String,
                updatedKind: String,
                originalContent: String? = nil,
                updatedContent: String? = nil) {
        self.relativePath = relativePath
        self.status = status
        self.originalKind = originalKind
        self.updatedKind = updatedKind
        self.originalContent = originalContent
        self.updatedContent = updatedContent
    }
}

public struct SkillBundleManifest: Codable, Equatable, Sendable {
    public var format: String
    public var exportedAt: Date
    public var skills: [SkillBundleManifestSkill]

    public init(format: String = "conductor.skill-bundle.v1",
                exportedAt: Date = Date(),
                skills: [SkillBundleManifestSkill]) {
        self.format = format
        self.exportedAt = exportedAt
        self.skills = skills
    }
}

public struct SkillBundleManifestSkill: Codable, Equatable, Sendable, Identifiable {
    public var id: String { directoryName }
    public var directoryName: String
    public var name: String
    public var description: String?
    public var sourceType: ManagedSkill.SourceType
    public var sourceRef: String?
    public var sourceSubpath: String?
    public var sourceBranch: String?
    public var sourceRevision: String?
    public var remoteRevision: String?
    public var updateStatus: String
    public var tags: [String]
    public var contentHash: String?

    public init(directoryName: String,
                name: String,
                description: String?,
                sourceType: ManagedSkill.SourceType,
                sourceRef: String?,
                sourceSubpath: String?,
                sourceBranch: String?,
                sourceRevision: String?,
                remoteRevision: String?,
                updateStatus: String,
                tags: [String],
                contentHash: String?) {
        self.directoryName = directoryName
        self.name = name
        self.description = description
        self.sourceType = sourceType
        self.sourceRef = sourceRef
        self.sourceSubpath = sourceSubpath
        self.sourceBranch = sourceBranch
        self.sourceRevision = sourceRevision
        self.remoteRevision = remoteRevision
        self.updateStatus = updateStatus
        self.tags = tags
        self.contentHash = contentHash
    }
}

public struct SkillBundleImportResult: Codable, Equatable, Sendable {
    public var installed: [ManagedSkill]
    public var skipped: Int

    public init(installed: [ManagedSkill], skipped: Int = 0) {
        self.installed = installed
        self.skipped = skipped
    }
}

public struct GitSkillPreview: Codable, Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String
    public var name: String
    public var description: String?

    public init(relativePath: String, name: String, description: String?) {
        self.relativePath = relativePath
        self.name = name
        self.description = description
    }
}

public struct SkillAuditEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var timestamp: Date
    public var action: String
    public var skillID: String?
    public var skillName: String?
    public var tool: String?
    public var success: Bool
    public var detail: String?

    public init(id: String = UUID().uuidString,
                timestamp: Date = Date(),
                action: String,
                skillID: String? = nil,
                skillName: String? = nil,
                tool: String? = nil,
                success: Bool = true,
                detail: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.skillID = skillID
        self.skillName = skillName
        self.tool = tool
        self.success = success
        self.detail = detail
    }
}

public struct SkillPresetSkill: Codable, Equatable, Sendable, Identifiable {
    public var id: String { skillID }
    public var skillID: String
    public var order: Int
    public var enabledToolKeys: [String]?

    public init(skillID: String, order: Int, enabledToolKeys: [String]? = nil) {
        self.skillID = skillID
        self.order = order
        self.enabledToolKeys = enabledToolKeys
    }
}

public struct SkillPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var icon: String?
    public var skills: [SkillPresetSkill]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                description: String? = nil,
                icon: String? = nil,
                skills: [SkillPresetSkill] = [],
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.skills = skills
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SkillPresetSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var icon: String?
    public var skillCount: Int
    public var syncedPairs: Int
    public var totalPairs: Int
    public var updatedAt: Date

    public init(id: String,
                name: String,
                description: String?,
                icon: String?,
                skillCount: Int,
                syncedPairs: Int,
                totalPairs: Int,
                updatedAt: Date) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.skillCount = skillCount
        self.syncedPairs = syncedPairs
        self.totalPairs = totalPairs
        self.updatedAt = updatedAt
    }
}

public struct SkillProject: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var bookmarkData: Data?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                path: String,
                bookmarkData: Data? = nil,
                sortOrder: Int = 0,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmarkData = bookmarkData
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SkillProjectTargetRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var projectID: String
    public var skillID: String
    public var tool: String
    public var targetPath: String
    public var mode: SkillTargetRecord.Mode
    public var status: String
    public var syncedAt: Date?
    public var lastError: String?
    public var sourceHash: String?

    public init(id: String = UUID().uuidString,
                projectID: String,
                skillID: String,
                tool: String,
                targetPath: String,
                mode: SkillTargetRecord.Mode,
                status: String = "ok",
                syncedAt: Date? = Date(),
                lastError: String? = nil,
                sourceHash: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.skillID = skillID
        self.tool = tool
        self.targetPath = targetPath
        self.mode = mode
        self.status = status
        self.syncedAt = syncedAt
        self.lastError = lastError
        self.sourceHash = sourceHash
    }
}

public struct ProjectSkillInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(tool)|\(relativePath)" }
    public var name: String
    public var dirName: String
    public var relativePath: String
    public var description: String?
    public var path: String
    public var files: [String]
    public var enabled: Bool
    public var tool: String
    public var toolDisplayName: String
    public var inCenter: Bool
    public var syncStatus: String
    public var centerSkillID: String?
    public var contentHash: String?
    public var modifiedAt: Date?

    public init(name: String,
                dirName: String,
                relativePath: String,
                description: String?,
                path: String,
                files: [String],
                enabled: Bool,
                tool: String,
                toolDisplayName: String,
                inCenter: Bool,
                syncStatus: String,
                centerSkillID: String?,
                contentHash: String?,
                modifiedAt: Date?) {
        self.name = name
        self.dirName = dirName
        self.relativePath = relativePath
        self.description = description
        self.path = path
        self.files = files
        self.enabled = enabled
        self.tool = tool
        self.toolDisplayName = toolDisplayName
        self.inCenter = inCenter
        self.syncStatus = syncStatus
        self.centerSkillID = centerSkillID
        self.contentHash = contentHash
        self.modifiedAt = modifiedAt
    }
}

public struct SkillProjectSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var skillCount: Int
    public var syncedTargetCount: Int
    public var updatedAt: Date

    public init(id: String,
                name: String,
                path: String,
                skillCount: Int,
                syncedTargetCount: Int,
                updatedAt: Date) {
        self.id = id
        self.name = name
        self.path = path
        self.skillCount = skillCount
        self.syncedTargetCount = syncedTargetCount
        self.updatedAt = updatedAt
    }
}
