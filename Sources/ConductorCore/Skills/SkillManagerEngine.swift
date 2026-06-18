import Foundation

public struct SkillInstallResult: Codable, Equatable, Sendable {
    public var skill: ManagedSkill
    public var createdNewCentralCopy: Bool
}

public final class SkillManagerEngine: @unchecked Sendable {
    public let rootDirectory: URL
    public let skillsDirectory: URL
    public let store: SkillManagerStore
    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(rootDirectory: URL? = nil,
                stateURL: URL? = nil,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default) throws {
        let root = rootDirectory ?? homeDirectory.appendingPathComponent(".skills-manager")
        self.rootDirectory = root
        self.skillsDirectory = root.appendingPathComponent("skills")
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.store = try SkillManagerStore(
            fileURL: stateURL ?? root.appendingPathComponent("skills-manager.json"),
            fileManager: fileManager)
        try fileManager.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
    }

    public func catalog() -> SkillToolCatalog {
        let state = store.snapshot()
        return SkillToolCatalog(
            adapters: SkillToolCatalog.defaultAdapters + state.customAdapters,
            disabledToolKeys: state.disabledToolKeys)
    }

    public func tools() -> [SkillToolInfo] {
        catalog().toolInfos(fileManager: fileManager)
    }

    public func listSkills() -> [ManagedSkill] {
        store.skills().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func listAudit(limit: Int = 120) -> [SkillAuditEntry] {
        store.auditLog(limit: limit)
    }

    public func fetchSkillsShLeaderboard(board: String = "alltime") throws -> [SkillsShSkill] {
        try SkillsshClient.fetchLeaderboard(board: board)
    }

    public func searchSkillsSh(query: String, limit: Int = 60) throws -> [SkillsShSkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try fetchSkillsShLeaderboard()
        }
        return try SkillsshClient.search(query: trimmed, limit: limit)
    }

    public func listPresets() -> [SkillPreset] {
        store.presets().sorted {
            $0.updatedAt > $1.updatedAt
        }
    }

    public func listProjects() -> [SkillProject] {
        store.projects().sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func listProjectTargets(projectID: String? = nil) -> [SkillProjectTargetRecord] {
        let targets = store.projectTargets()
        guard let projectID else { return targets }
        return targets.filter { $0.projectID == projectID }
    }

    public func projectSummaries() -> [SkillProjectSummary] {
        listProjects().map { project in
            SkillProjectSummary(
                id: project.id,
                name: project.name,
                path: project.path,
                skillCount: readProjectSkills(projectID: project.id).count,
                syncedTargetCount: listProjectTargets(projectID: project.id).count,
                updatedAt: project.updatedAt)
        }
    }

    public func projectToolInfos() -> [SkillToolInfo] {
        tools().filter { info in
            info.enabled && info.projectRelativeSkillsDir?.isEmpty == false
        }
    }

    public func presetSummaries(toolKeys: [String]? = nil) -> [SkillPresetSummary] {
        let skills = store.skills()
        let skillByID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        let defaultToolKeys = toolKeys ?? tools()
            .filter { $0.enabled && ($0.installed || $0.isCustom || $0.hasPathOverride) }
            .map(\.key)

        return listPresets().map { preset in
            var totalPairs = 0
            var syncedPairs = 0
            for item in preset.skills {
                guard let skill = skillByID[item.skillID] else { continue }
                let keys = item.enabledToolKeys ?? defaultToolKeys
                totalPairs += keys.count
                for key in keys where skill.targets.contains(where: { $0.tool == key }) {
                    syncedPairs += 1
                }
            }
            return SkillPresetSummary(
                id: preset.id,
                name: preset.name,
                description: preset.description,
                icon: preset.icon,
                skillCount: preset.skills.count,
                syncedPairs: syncedPairs,
                totalPairs: totalPairs,
                updatedAt: preset.updatedAt)
        }
    }

    @discardableResult
    public func createPreset(name: String,
                             description: String? = nil,
                             icon: String? = nil,
                             skillIDs: [String] = []) throws -> SkillPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillManagerError.invalidSkillName(name)
        }
        try ensureSkillsExist(skillIDs)
        let preset = SkillPreset(
            name: trimmed,
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            skills: orderedPresetSkills(skillIDs))
        try store.upsertPreset(preset)
        audit("preset_create", detail: trimmed)
        return preset
    }

    @discardableResult
    public func updatePreset(id presetID: String,
                             name: String? = nil,
                             description: String? = nil,
                             icon: String? = nil) throws -> SkillPreset {
        guard var preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw SkillManagerError.invalidSkillName(name)
            }
            preset.name = trimmed
        }
        if let description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            preset.description = trimmed.isEmpty ? nil : trimmed
        }
        if let icon { preset.icon = icon }
        preset.updatedAt = Date()
        try store.upsertPreset(preset)
        return preset
    }

    public func deletePreset(id presetID: String) throws {
        guard store.preset(id: presetID) != nil else {
            throw SkillManagerError.missingPreset(presetID)
        }
        try store.deletePreset(id: presetID)
        audit("preset_delete", detail: presetID)
    }

    @discardableResult
    public func setPresetSkills(presetID: String,
                                skillIDs: [String]) throws -> SkillPreset {
        guard var preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        try ensureSkillsExist(skillIDs)
        let existing = Dictionary(uniqueKeysWithValues: preset.skills.map { ($0.skillID, $0) })
        preset.skills = uniqueStrings(skillIDs).enumerated().map { index, skillID in
            SkillPresetSkill(
                skillID: skillID,
                order: index,
                enabledToolKeys: existing[skillID]?.enabledToolKeys)
        }
        preset.updatedAt = Date()
        try store.upsertPreset(preset)
        audit("preset_reorder", detail: preset.name)
        return preset
    }

    @discardableResult
    public func moveSkillInPreset(presetID: String,
                                  skillID: String,
                                  offset: Int) throws -> SkillPreset {
        guard var preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        var items = normalizePresetOrder(preset.skills)
        guard let index = items.firstIndex(where: { $0.skillID == skillID }) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        guard offset != 0 else { return preset }

        let destination = max(0, min(items.count - 1, index + offset))
        guard destination != index else { return preset }

        let item = items.remove(at: index)
        items.insert(item, at: destination)
        // 按数组新位置重排 order。不能再走 normalizePresetOrder——它先按 order 排序，
        // 而被移动的 item 还带着旧 order，会把刚做的移动又抵消掉（reorder 此前不生效的根因）。
        for i in items.indices { items[i].order = i }
        preset.skills = items
        preset.updatedAt = Date()
        try store.upsertPreset(preset)
        audit("preset_reorder", detail: preset.name)
        return preset
    }

    @discardableResult
    public func addSkillToPreset(presetID: String,
                                 skillID: String,
                                 enabledToolKeys: [String]? = nil) throws -> SkillPreset {
        guard var preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        guard store.skill(id: skillID) != nil else {
            throw SkillManagerError.missingSkill(skillID)
        }
        if let index = preset.skills.firstIndex(where: { $0.skillID == skillID }) {
            preset.skills[index].enabledToolKeys = enabledToolKeys
        } else {
            preset.skills.append(SkillPresetSkill(
                skillID: skillID,
                order: preset.skills.count,
                enabledToolKeys: enabledToolKeys))
        }
        preset.skills = normalizePresetOrder(preset.skills)
        preset.updatedAt = Date()
        try store.upsertPreset(preset)
        return preset
    }

    @discardableResult
    public func removeSkillFromPreset(presetID: String, skillID: String) throws -> SkillPreset {
        guard var preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        preset.skills.removeAll { $0.skillID == skillID }
        preset.skills = normalizePresetOrder(preset.skills)
        preset.updatedAt = Date()
        try store.upsertPreset(preset)
        return preset
    }

    public func applyPreset(id presetID: String,
                            toTools toolKeys: [String],
                            mode: SkillTargetRecord.Mode = .symlink) throws -> [SkillTargetRecord] {
        guard let preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        let requestedTools = uniqueStrings(toolKeys)
        var records: [SkillTargetRecord] = []
        for item in preset.skills.sorted(by: { $0.order < $1.order }) {
            guard store.skill(id: item.skillID) != nil else { continue }
            let keys = item.enabledToolKeys.map { uniqueStrings($0) } ?? requestedTools
            for key in keys where requestedTools.contains(key) {
                records.append(try syncSkill(id: item.skillID, toTool: key, mode: mode))
            }
        }
        return records
    }

    public func removePreset(id presetID: String, fromTools toolKeys: [String]? = nil) throws {
        guard let preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        let requestedTools = toolKeys.map(uniqueStrings)
        for item in preset.skills {
            guard let skill = store.skill(id: item.skillID) else { continue }
            let keys = requestedTools ?? skill.targets.map(\.tool)
            for key in keys {
                try unsyncSkill(id: item.skillID, fromTool: key)
            }
        }
    }

    @discardableResult
    public func addProject(path: URL,
                           name explicitName: String? = nil,
                           bookmarkData: Data? = nil) throws -> SkillProject {
        let access = SecurityScopedBookmarks.startAccessing(bookmarkData)
        defer { access?.stop() }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SkillManagerError.invalidSkillDirectory(path.path)
        }

        let projectPath = path.standardizedFileURL.path
        let name = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false ? name! : path.lastPathComponent)
        let sortOrder = store.projects().map(\.sortOrder).max().map { $0 + 1 } ?? 0

        let project: SkillProject
        if var existing = store.projects().first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == projectPath
        }) {
            existing.name = resolvedName
            if let bookmarkData {
                existing.bookmarkData = bookmarkData
            }
            existing.updatedAt = Date()
            project = existing
        } else {
            project = SkillProject(
                name: resolvedName,
                path: projectPath,
                bookmarkData: bookmarkData,
                sortOrder: sortOrder)
        }
        try store.upsertProject(project)
        return project
    }

    public func deleteProject(id projectID: String, removeSyncedTargets: Bool = false) throws {
        guard let project = store.project(id: projectID) else {
            throw SkillManagerError.missingProject(projectID)
        }
        let access = SecurityScopedBookmarks.startAccessing(project.bookmarkData)
        defer { access?.stop() }

        if removeSyncedTargets {
            for target in listProjectTargets(projectID: project.id) {
                try SkillFileUtilities.removeTarget(
                    at: URL(fileURLWithPath: target.targetPath),
                    fileManager: fileManager)
            }
        }
        try store.deleteProject(id: projectID)
    }

    public func readProjectSkills(projectID: String) -> [ProjectSkillInfo] {
        guard let project = store.project(id: projectID) else { return [] }
        let access = SecurityScopedBookmarks.startAccessing(project.bookmarkData)
        defer { access?.stop() }

        let root = URL(fileURLWithPath: project.path)
        let managedSkills = store.skills()
        let targets = listProjectTargets(projectID: projectID)
        var seen = Set<String>()
        var out: [ProjectSkillInfo] = []

        for adapter in projectAdapters() {
            guard let relative = adapter.effectiveProjectRelativeSkillsDir,
                  !relative.isEmpty else { continue }
            let skillsRoot = root.appendingPathComponent(relative)
            let skillDirs = SkillFileUtilities.collectSkillDirectories(
                in: skillsRoot,
                recursive: adapter.recursiveScan,
                centralDirectory: skillsDirectory,
                fileManager: fileManager)
            for skillDir in skillDirs {
                let key = "\(adapter.key)|\(skillDir.standardizedFileURL.path)"
                guard seen.insert(key).inserted else { continue }
                let metadata = SkillMetadataParser.parse(directory: skillDir, fileManager: fileManager)
                let dirName = skillDir.lastPathComponent
                let hash = try? SkillFileUtilities.hashDirectory(skillDir, fileManager: fileManager)
                let centerMatch = matchProjectSkill(
                    path: skillDir.standardizedFileURL.path,
                    name: metadata.name ?? dirName,
                    fingerprint: hash,
                    managedSkills: managedSkills,
                    projectTargets: targets)
                let files = (try? fileManager.contentsOfDirectory(
                    at: skillDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]))?
                    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                    .map(\.lastPathComponent)
                    .sorted() ?? []

                out.append(ProjectSkillInfo(
                    name: metadata.name ?? dirName,
                    dirName: dirName,
                    relativePath: relativePath(from: skillsRoot, to: skillDir),
                    description: metadata.description,
                    path: skillDir.path,
                    files: files,
                    enabled: true,
                    tool: adapter.key,
                    toolDisplayName: adapter.displayName,
                    inCenter: centerMatch.skill != nil,
                    syncStatus: centerMatch.status,
                    centerSkillID: centerMatch.skill?.id,
                    contentHash: hash,
                    modifiedAt: modificationDate(for: skillDir)))
            }
        }

        return out.sorted {
            if $0.tool != $1.tool { return $0.tool < $1.tool }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    public func syncSkillToProject(skillID: String,
                                   projectID: String,
                                   toolKey: String,
                                   mode requestedMode: SkillTargetRecord.Mode = .symlink) throws -> SkillProjectTargetRecord {
        guard let skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        guard let project = store.project(id: projectID) else {
            throw SkillManagerError.missingProject(projectID)
        }
        guard let adapter = catalog().adapter(for: toolKey) else {
            throw SkillManagerError.missingTool(toolKey)
        }
        guard let relative = adapter.effectiveProjectRelativeSkillsDir, !relative.isEmpty else {
            throw SkillManagerError.missingTool(toolKey)
        }
        let projectAccess = SecurityScopedBookmarks.startAccessing(project.bookmarkData)
        defer { projectAccess?.stop() }

        let source = URL(fileURLWithPath: skill.centralPath)
        let currentHash = try? SkillFileUtilities.hashDirectory(source, fileManager: fileManager)
        let targetName = source.lastPathComponent.isEmpty ? skill.name : source.lastPathComponent
        let target = URL(fileURLWithPath: project.path)
            .appendingPathComponent(relative)
            .appendingPathComponent(targetName)
        let existingProjectTarget = store.projectTargets().first {
            $0.projectID == projectID && $0.skillID == skillID && $0.tool == toolKey
        }
        let existingRecord = existingProjectTarget.map {
            SkillTargetRecord(
                id: $0.id,
                skillID: $0.skillID,
                tool: $0.tool,
                targetPath: $0.targetPath,
                mode: $0.mode,
                status: $0.status,
                syncedAt: $0.syncedAt,
                lastError: $0.lastError,
                sourceHash: $0.sourceHash)
        }

        let actualMode = try SkillFileUtilities.syncSkill(
            source: source,
            target: target,
            mode: requestedMode,
            existingRecord: existingRecord,
            currentHash: currentHash,
            fileManager: fileManager)

        let record = SkillProjectTargetRecord(
            id: existingProjectTarget?.id ?? UUID().uuidString,
            projectID: projectID,
            skillID: skillID,
            tool: toolKey,
            targetPath: target.path,
            mode: actualMode,
            status: "ok",
            syncedAt: Date(),
            lastError: nil,
            sourceHash: currentHash)
        try store.upsertProjectTarget(record)
        audit("project_sync", skill: skill, tool: toolKey, detail: project.name)
        return record
    }

    public func unsyncSkillFromProject(skillID: String, projectID: String, toolKey: String) throws {
        guard let project = store.project(id: projectID) else {
            throw SkillManagerError.missingProject(projectID)
        }
        let projectAccess = SecurityScopedBookmarks.startAccessing(project.bookmarkData)
        defer { projectAccess?.stop() }

        guard let target = store.projectTargets().first(where: {
            $0.projectID == projectID && $0.skillID == skillID && $0.tool == toolKey
        }) else {
            return
        }
        try SkillFileUtilities.removeTarget(at: URL(fileURLWithPath: target.targetPath), fileManager: fileManager)
        try store.deleteProjectTarget(projectID: projectID, skillID: skillID, tool: toolKey)
        if let skill = store.skill(id: skillID), let project = store.project(id: projectID) {
            audit("project_unsync", skill: skill, tool: toolKey, detail: project.name)
        }
    }

    public func applyPresetToProject(presetID: String,
                                     projectID: String,
                                     toolKeys: [String],
                                     mode: SkillTargetRecord.Mode = .symlink) throws -> [SkillProjectTargetRecord] {
        guard let preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        guard store.project(id: projectID) != nil else {
            throw SkillManagerError.missingProject(projectID)
        }
        let requestedTools = uniqueStrings(toolKeys)
        var records: [SkillProjectTargetRecord] = []
        for item in preset.skills.sorted(by: { $0.order < $1.order }) {
            let keys = item.enabledToolKeys.map { uniqueStrings($0) } ?? requestedTools
            for key in keys where requestedTools.contains(key) {
                records.append(try syncSkillToProject(
                    skillID: item.skillID,
                    projectID: projectID,
                    toolKey: key,
                    mode: mode))
            }
        }
        return records
    }

    public func removePresetFromProject(presetID: String,
                                        projectID: String,
                                        toolKeys: [String]? = nil) throws {
        guard let preset = store.preset(id: presetID) else {
            throw SkillManagerError.missingPreset(presetID)
        }
        let requestedTools = toolKeys.map(uniqueStrings)
        for item in preset.skills {
            let keys = requestedTools ?? store.projectTargets()
                .filter { $0.projectID == projectID && $0.skillID == item.skillID }
                .map(\.tool)
            for key in keys {
                try unsyncSkillFromProject(skillID: item.skillID, projectID: projectID, toolKey: key)
            }
        }
    }

    @discardableResult
    public func installLocalSkill(source: URL,
                                  name explicitName: String? = nil,
                                  sourceType: ManagedSkill.SourceType = .local,
                                  sourceRef: String? = nil,
                                  sourceSubpath: String? = nil,
                                  sourceBranch: String? = nil,
                                  sourceRevision: String? = nil,
                                  remoteRevision: String? = nil,
                                  sourceBookmarkData: Data? = nil,
                                  updateStatus: String? = nil,
                                  tags: [String] = []) throws -> SkillInstallResult {
        let sourceAccess = SecurityScopedBookmarks.startAccessing(sourceBookmarkData)
        defer { sourceAccess?.stop() }

        let sourceDirectory = try prepareLocalSource(source)
        guard SkillMetadataParser.isValidSkillDirectory(sourceDirectory, fileManager: fileManager) else {
            throw SkillManagerError.invalidSkillDirectory(source.path)
        }

        let sanitizedName: String
        if let explicitName, !explicitName.isEmpty {
            guard let sanitized = SkillMetadataParser.sanitizeSkillName(explicitName) else {
                throw SkillManagerError.invalidSkillName(explicitName)
            }
            sanitizedName = sanitized
        } else {
            sanitizedName = SkillMetadataParser.inferSkillName(for: sourceDirectory, fileManager: fileManager)
        }

        let destination = try uniqueSkillDestination(
            parent: skillsDirectory,
            sanitizedName: sanitizedName,
            source: sourceDirectory)
        let existed = fileManager.fileExists(atPath: destination.path)
        let sourcePath = sourceDirectory.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        if sourcePath != destinationPath {
            try SkillFileUtilities.copySkillDirectory(
                from: sourceDirectory,
                to: destination,
                fileManager: fileManager)
        }

        let metadata = SkillMetadataParser.parse(directory: destination, fileManager: fileManager)
        let hash = try SkillFileUtilities.hashDirectory(destination, fileManager: fileManager)
        let resolvedName = metadata.name.flatMap(SkillMetadataParser.sanitizeSkillName) ?? destination.lastPathComponent
        let resolvedSourceRef = sourceRef ?? source.path
        let record: ManagedSkill
        if var existing = store.skills().first(where: {
            URL(fileURLWithPath: $0.centralPath).standardizedFileURL.path == destinationPath
        }) {
            existing.name = resolvedName
            existing.description = metadata.description
            existing.sourceType = sourceType
            existing.sourceRef = resolvedSourceRef
            existing.sourceSubpath = sourceSubpath
            existing.sourceBranch = sourceBranch
            existing.sourceRevision = sourceRevision
            existing.remoteRevision = remoteRevision
            existing.sourceBookmarkData = sourceBookmarkData
            if let updateStatus {
                existing.updateStatus = updateStatus
            }
            existing.contentHash = hash
            existing.updatedAt = Date()
            existing.tags = orderedUnion(existing.tags, tags)
            record = existing
        } else {
            record = ManagedSkill(
                name: resolvedName,
                description: metadata.description,
                sourceType: sourceType,
                sourceRef: resolvedSourceRef,
                sourceSubpath: sourceSubpath,
                sourceBranch: sourceBranch,
                sourceRevision: sourceRevision,
                remoteRevision: remoteRevision,
                sourceBookmarkData: sourceBookmarkData,
                centralPath: destination.path,
                contentHash: hash,
                updateStatus: updateStatus ?? "unknown",
                tags: tags)
        }
        try store.upsertSkill(record)
        audit(
            "install",
            skill: record,
            detail: [sourceType.rawValue, resolvedSourceRef]
                .filter { !$0.isEmpty }
                .joined(separator: ": "))
        return SkillInstallResult(skill: record, createdNewCentralCopy: !existed)
    }

    @discardableResult
    public func installLocalSkills(source: URL,
                                   name explicitName: String? = nil,
                                   sourceBookmarkData: Data? = nil,
                                   tags: [String] = []) throws -> [SkillInstallResult] {
        let sourceAccess = SecurityScopedBookmarks.startAccessing(sourceBookmarkData)
        defer { sourceAccess?.stop() }

        let prepared = try prepareLocalImportRoot(source)
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? fileManager.removeItem(at: cleanupURL)
            }
        }

        let root = prepared.directory
        let candidates: [URL]
        if SkillMetadataParser.isValidSkillDirectory(root, fileManager: fileManager) {
            candidates = [root]
        } else {
            candidates = SkillFileUtilities.collectSkillDirectories(
                in: root,
                recursive: true,
                centralDirectory: skillsDirectory,
                fileManager: fileManager)
                .sorted { lhs, rhs in
                    lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
                }
        }

        guard !candidates.isEmpty else {
            throw SkillManagerError.invalidSkillDirectory(source.path)
        }

        let useExplicitName = candidates.count == 1 ? explicitName : nil
        return try candidates.map { candidate in
            let sourceRef: String
            let sourceSubpath: String?
            if prepared.isArchive {
                sourceRef = source.path
                let relative = relativePath(from: root, to: candidate)
                sourceSubpath = relative.isEmpty ? nil : relative
            } else {
                sourceRef = candidate.path
                sourceSubpath = nil
            }
            return try installLocalSkill(
                source: candidate,
                name: useExplicitName,
                sourceType: .local,
                sourceRef: sourceRef,
                sourceSubpath: sourceSubpath,
                sourceBookmarkData: sourceBookmarkData,
                tags: tags)
        }
    }

    @discardableResult
    public func exportSkillBundle(skillIDs: [String]? = nil, to destination: URL) throws -> URL {
        let skills = try skillsForBundleExport(skillIDs)
        guard !skills.isEmpty else {
            throw SkillManagerError.missingSkill("No skills selected for export.")
        }

        let tmpRoot = rootDirectory.appendingPathComponent("tmp")
        try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let staging = tmpRoot.appendingPathComponent("bundle-\(UUID().uuidString)")
        let bundleSkillsRoot = staging.appendingPathComponent("skills")
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.createDirectory(at: bundleSkillsRoot, withIntermediateDirectories: true)

        var usedDirectoryNames = Set<String>()
        var manifestSkills: [SkillBundleManifestSkill] = []
        for skill in skills {
            let source = URL(fileURLWithPath: skill.centralPath)
            let directoryName = uniqueBundleDirectoryName(for: skill, used: &usedDirectoryNames)
            let target = bundleSkillsRoot.appendingPathComponent(directoryName)
            try SkillFileUtilities.copySkillDirectory(
                from: source,
                to: target,
                fileManager: fileManager)
            manifestSkills.append(bundleManifestSkill(for: skill, directoryName: directoryName))
        }

        let manifest = SkillBundleManifest(skills: manifestSkills)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("skill-bundle.json"))

        let resolvedDestination = destination.pathExtension.isEmpty
            ? destination.appendingPathExtension("zip")
            : destination
        try fileManager.createDirectory(
            at: resolvedDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: resolvedDestination.path) {
            try fileManager.removeItem(at: resolvedDestination)
        }
        try runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", staging.path, resolvedDestination.path],
            failurePrefix: "Failed to create skill bundle \(resolvedDestination.path)")
        audit("bundle_export", detail: "\(skills.count) skills -> \(resolvedDestination.path)")
        return resolvedDestination
    }

    @discardableResult
    public func importSkillBundle(source: URL,
                                  sourceBookmarkData: Data? = nil,
                                  tags: [String] = []) throws -> SkillBundleImportResult {
        let sourceAccess = SecurityScopedBookmarks.startAccessing(sourceBookmarkData)
        defer { sourceAccess?.stop() }

        let prepared = try prepareLocalImportRoot(source)
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? fileManager.removeItem(at: cleanupURL)
            }
        }

        guard let manifestURL = findBundleManifest(in: prepared.directory) else {
            let installed = try installLocalSkills(
                source: source,
                sourceBookmarkData: sourceBookmarkData,
                tags: tags).map(\.skill)
            return SkillBundleImportResult(installed: installed)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            SkillBundleManifest.self,
            from: Data(contentsOf: manifestURL))
        guard manifest.format == "conductor.skill-bundle.v1" else {
            throw SkillManagerError.archiveFailed("Unsupported skill bundle format: \(manifest.format)")
        }

        let bundleRoot = manifestURL.deletingLastPathComponent()
        let skillsRoot = bundleRoot.appendingPathComponent("skills")
        let extraTags = normalizeTags(tags)
        var installed: [ManagedSkill] = []
        var skipped = 0
        for entry in manifest.skills {
            if let skill = try installBundleManifestSkill(
                entry,
                skillsRoot: skillsRoot,
                extraTags: extraTags) {
                installed.append(skill)
            } else {
                skipped += 1
            }
        }
        audit("bundle_import", detail: "\(installed.count) installed, \(skipped) skipped")
        return SkillBundleImportResult(installed: installed, skipped: skipped)
    }

    @discardableResult
    public func importDiscoveredSkill(recordID: String,
                                      name: String? = nil,
                                      tags: [String] = []) throws -> ManagedSkill {
        guard let record = store.discovered().first(where: { $0.id == recordID }) else {
            throw SkillManagerError.missingSkill(recordID)
        }
        let result = try installLocalSkill(
            source: URL(fileURLWithPath: record.foundPath),
            name: name ?? record.nameGuess,
            sourceType: .imported,
            sourceRef: record.foundPath,
            sourceBookmarkData: record.bookmarkData,
            tags: tags)

        var updated = store.discovered()
        if let index = updated.firstIndex(where: { $0.id == recordID }) {
            updated[index].importedSkillID = result.skill.id
            try store.replaceDiscovered(updated)
        }
        return result.skill
    }

    @discardableResult
    public func importAllDiscoveredSkills(tags: [String] = []) throws -> [ManagedSkill] {
        let groups = groupDiscovered(store.discovered()).filter { !$0.imported }
        var imported: [ManagedSkill] = []
        for group in groups {
            guard let id = group.locations.first?.id else { continue }
            imported.append(try importDiscoveredSkill(recordID: id, name: group.name, tags: tags))
        }
        return imported
    }

    @discardableResult
    public func installGitSkill(repositoryURL: String,
                                subdirectory: String? = nil,
                                ref: String? = nil,
                                name: String? = nil,
                                tags: [String] = []) throws -> SkillInstallResult {
        let remote = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            throw SkillManagerError.gitFailed("Git repository URL is empty.")
        }
        let trimmedSubdirectory = subdirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines)

        let tmpRoot = rootDirectory.appendingPathComponent("tmp")
        try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let cloneRoot = tmpRoot.appendingPathComponent("git-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: cloneRoot) }

        try runGit(in: tmpRoot, ["clone", remote, cloneRoot.path])
        if let ref = trimmedRef, !ref.isEmpty {
            try runGit(in: cloneRoot, ["checkout", ref])
        }

        let source = try resolveGitSkillSource(
            cloneRoot: cloneRoot,
            subdirectory: trimmedSubdirectory)
        let revision = optionalGit(in: cloneRoot, ["rev-parse", "HEAD"])
        return try installLocalSkill(
            source: source,
            name: name,
            sourceType: .git,
            sourceRef: remote,
            sourceSubpath: trimmedSubdirectory?.isEmpty == false ? trimmedSubdirectory : nil,
            sourceBranch: trimmedRef?.isEmpty == false ? trimmedRef : nil,
            sourceRevision: revision,
            remoteRevision: revision,
            updateStatus: "current",
            tags: tags)
    }

    @discardableResult
    public func installGitSkills(repositoryURL: String,
                                 subdirectory: String? = nil,
                                 ref: String? = nil,
                                 selectedSubpaths: [String]? = nil,
                                 tags: [String] = []) throws -> [SkillInstallResult] {
        let remote = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            throw SkillManagerError.gitFailed("Git repository URL is empty.")
        }
        let trimmedSubdirectory = subdirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines)

        let tmpRoot = rootDirectory.appendingPathComponent("tmp")
        try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let cloneRoot = tmpRoot.appendingPathComponent("git-multi-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: cloneRoot) }

        try runGit(in: tmpRoot, ["clone", remote, cloneRoot.path])
        if let ref = trimmedRef, !ref.isEmpty {
            try runGit(in: cloneRoot, ["checkout", ref])
        }

        let scanRoot = gitScanRoot(cloneRoot: cloneRoot, subdirectory: trimmedSubdirectory)
        var candidates = try gitSkillCandidates(in: scanRoot)
        if let selectedSubpaths {
            let selected = Set(selectedSubpaths.map(normalizeGitPreviewPath))
            candidates = candidates.filter { selected.contains(gitPreviewPath(scanRoot: scanRoot, skillDirectory: $0)) }
        }
        guard !candidates.isEmpty else {
            throw SkillManagerError.invalidSkillDirectory(scanRoot.path)
        }

        let revision = optionalGit(in: cloneRoot, ["rev-parse", "HEAD"])
        return try candidates.map { source in
            let subpath = relativePath(from: cloneRoot, to: source)
            return try installLocalSkill(
                source: source,
                sourceType: .git,
                sourceRef: remote,
                sourceSubpath: subpath.isEmpty ? nil : subpath,
                sourceBranch: trimmedRef?.isEmpty == false ? trimmedRef : nil,
                sourceRevision: revision,
                remoteRevision: revision,
                updateStatus: "current",
                tags: tags)
        }
    }

    public func previewGitSkills(repositoryURL: String,
                                 subdirectory: String? = nil,
                                 ref: String? = nil) throws -> [GitSkillPreview] {
        let remote = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            throw SkillManagerError.gitFailed("Git repository URL is empty.")
        }
        let trimmedSubdirectory = subdirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines)

        let tmpRoot = rootDirectory.appendingPathComponent("tmp")
        try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let cloneRoot = tmpRoot.appendingPathComponent("git-preview-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: cloneRoot) }

        try runGit(in: tmpRoot, ["clone", remote, cloneRoot.path])
        if let ref = trimmedRef, !ref.isEmpty {
            try runGit(in: cloneRoot, ["checkout", ref])
        }

        let scanRoot = gitScanRoot(cloneRoot: cloneRoot, subdirectory: trimmedSubdirectory)
        return try gitSkillCandidates(in: scanRoot).map { candidate in
            let metadata = SkillMetadataParser.parse(directory: candidate, fileManager: fileManager)
            let fallbackName = candidate.lastPathComponent.isEmpty
                ? normalizeGitPreviewPath(relativePath(from: scanRoot, to: candidate))
                : candidate.lastPathComponent
            let trimmedName = metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitSkillPreview(
                relativePath: gitPreviewPath(scanRoot: scanRoot, skillDirectory: candidate),
                name: trimmedName?.isEmpty == false ? trimmedName! : fallbackName,
                description: trimmedDescription?.isEmpty == false ? trimmedDescription : nil)
        }
    }

    @discardableResult
    public func installSkillsshSkill(source: String,
                                     skillID: String,
                                     tags: [String] = []) throws -> SkillInstallResult {
        let repoSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedSkillID = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoSource.isEmpty, !trimmedSkillID.isEmpty else {
            throw SkillManagerError.invalidSkillName(skillID)
        }

        let sourceRef = "\(repoSource)/\(trimmedSkillID)"
        let repoURL = skillsshRepositoryURL(repoSource: repoSource)
        let tmpRoot = rootDirectory.appendingPathComponent("tmp")
        try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let cloneRoot = tmpRoot.appendingPathComponent("skillssh-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: cloneRoot) }

        try runGit(in: tmpRoot, ["clone", repoURL, cloneRoot.path])
        let sourceDirectory = try resolveSkillsshSource(
            cloneRoot: cloneRoot,
            skillID: trimmedSkillID,
            subdirectory: nil)
        let revision = optionalGit(in: cloneRoot, ["rev-parse", "HEAD"])

        if let existing = store.skills().first(where: {
            $0.sourceType == .skillssh && $0.sourceRef == sourceRef
        }) {
            let updated = try replaceCentralSkill(
                existing,
                withSource: sourceDirectory,
                sourceRevision: revision)
            return SkillInstallResult(skill: updated, createdNewCentralCopy: false)
        }

        let subpath = relativePath(from: cloneRoot, to: sourceDirectory)
        return try installLocalSkill(
            source: sourceDirectory,
            name: trimmedSkillID,
            sourceType: .skillssh,
            sourceRef: sourceRef,
            sourceSubpath: subpath.isEmpty ? nil : subpath,
            sourceBranch: nil,
            sourceRevision: revision,
            remoteRevision: revision,
            updateStatus: "current",
            tags: tags)
    }

    public func readSkillDocument(skillID: String, maxBytes: Int = 180_000) throws -> SkillDocument {
        guard let skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        let directory = URL(fileURLWithPath: skill.centralPath)
        let candidates = ["SKILL.md", "skill.md"]
        guard let file = candidates
            .map({ directory.appendingPathComponent($0) })
            .first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw SkillManagerError.invalidSkillDirectory(skill.centralPath)
        }
        let data = try Data(contentsOf: file)
        let truncated = data.count > maxBytes
        let contentData = truncated ? data.prefix(maxBytes) : data[...]
        let content = String(data: Data(contentData), encoding: .utf8) ?? ""
        return SkillDocument(
            skillID: skillID,
            filename: file.lastPathComponent,
            content: content,
            centralPath: skill.centralPath,
            truncated: truncated)
    }

    public func listSkillFiles(skillID: String, limit: Int = 80) throws -> [SkillFileInfo] {
        guard let skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        let root = URL(fileURLWithPath: skill.centralPath)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        var files: [SkillFileInfo] = []
        for case let url as URL in enumerator {
            guard files.count < limit else { break }
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard values?.isRegularFile == true else { continue }
            files.append(SkillFileInfo(
                relativePath: relativePath(from: root, to: url),
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate))
        }
        return files.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    public func readSkillSourceDiff(skillID: String,
                                    maxFileBytes: Int = 80_000,
                                    limit: Int = 120) throws -> SkillSourceDiff {
        guard let skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        let central = URL(fileURLWithPath: skill.centralPath)
        let source = try resolveSourceDirectoryForPreview(skill)
        defer {
            source.access?.stop()
            if let cleanupURL = source.cleanupURL {
                try? fileManager.removeItem(at: cleanupURL)
            }
        }
        return SkillSourceDiff(
            skillID: skillID,
            sourcePath: source.directory.path,
            entries: try buildSourceDiffEntries(
                original: central,
                updated: source.directory,
                maxFileBytes: maxFileBytes,
                limit: limit))
    }

    @discardableResult
    public func refreshSkillFromSource(id skillID: String) throws -> ManagedSkill {
        guard let skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }

        switch skill.sourceType {
        case .local, .imported:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.invalidSkillDirectory(skill.centralPath)
            }
            let sourceAccess = SecurityScopedBookmarks.startAccessing(skill.sourceBookmarkData)
            defer { sourceAccess?.stop() }

            let prepared = try prepareLocalImportRoot(URL(fileURLWithPath: sourceRef))
            defer {
                if let cleanupURL = prepared.cleanupURL {
                    try? fileManager.removeItem(at: cleanupURL)
                }
            }
            let source = try resolveLocalSkillSource(
                root: prepared.directory,
                subpath: skill.sourceSubpath,
                originalPath: sourceRef)
            return try replaceCentralSkill(skill, withSource: source, sourceRevision: nil)
        case .git:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.gitFailed("Git skill has no source repository.")
            }
            let tmpRoot = rootDirectory.appendingPathComponent("tmp")
            try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
            let cloneRoot = tmpRoot.appendingPathComponent("git-refresh-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: cloneRoot) }
            try runGit(in: tmpRoot, ["clone", sourceRef, cloneRoot.path])
            if let branch = skill.sourceBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
               !branch.isEmpty {
                try runGit(in: cloneRoot, ["checkout", branch])
            }
            let source = try resolveGitSkillSource(
                cloneRoot: cloneRoot,
                subdirectory: skill.sourceSubpath)
            let revision = optionalGit(in: cloneRoot, ["rev-parse", "HEAD"])
            return try replaceCentralSkill(skill, withSource: source, sourceRevision: revision)
        case .skillssh:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.gitFailed("skills.sh skill has no source reference.")
            }
            let checkout = try cloneSkillsshSource(
                sourceRef: sourceRef,
                branch: skill.sourceBranch,
                subpath: skill.sourceSubpath,
                prefix: "skillssh-refresh")
            defer { try? fileManager.removeItem(at: checkout.cloneRoot) }
            return try replaceCentralSkill(
                skill,
                withSource: checkout.sourceDirectory,
                sourceRevision: checkout.revision)
        }
    }

    @discardableResult
    public func checkSkillUpdate(id skillID: String) throws -> ManagedSkill {
        guard var skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }

        do {
            let snapshot = try sourceSnapshot(for: skill)
            let hashChanged = snapshot.contentHash != skill.contentHash
            let revisionChanged = snapshot.revision != nil && snapshot.revision != skill.sourceRevision
            skill.remoteRevision = snapshot.revision ?? snapshot.contentHash
            skill.updateStatus = (hashChanged || revisionChanged) ? "update_available" : "current"
            skill.status = "ok"
            skill.lastCheckError = nil
        } catch SkillManagerError.unsupportedArchive(let message),
                SkillManagerError.invalidSkillDirectory(let message),
                SkillManagerError.archiveFailed(let message) {
            skill.updateStatus = "source_missing"
            skill.status = "error"
            skill.lastCheckError = message
        } catch SkillManagerError.gitFailed(let message) {
            skill.updateStatus = "error"
            skill.status = "error"
            skill.lastCheckError = message
        } catch {
            skill.updateStatus = "error"
            skill.status = "error"
            skill.lastCheckError = error.localizedDescription
        }

        let now = Date()
        skill.lastCheckedAt = now
        skill.updatedAt = now
        try store.upsertSkill(skill)
        audit(
            "check_update",
            skill: skill,
            success: skill.status == "ok",
            detail: skill.lastCheckError ?? skill.updateStatus)
        return skill
    }

    @discardableResult
    public func checkSkillUpdates(ids skillIDs: [String]) throws -> [ManagedSkill] {
        var updated: [ManagedSkill] = []
        for id in uniqueStrings(skillIDs) {
            updated.append(try checkSkillUpdate(id: id))
        }
        return updated
    }

    @discardableResult
    public func relinkSkillSource(id skillID: String,
                                  source: URL,
                                  sourceBookmarkData: Data? = nil) throws -> ManagedSkill {
        guard var skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        let sourceAccess = SecurityScopedBookmarks.startAccessing(sourceBookmarkData)
        defer { sourceAccess?.stop() }

        let prepared = try prepareLocalImportRoot(source)
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? fileManager.removeItem(at: cleanupURL)
            }
        }
        let resolved = try resolveLocalSkillSource(
            root: prepared.directory,
            subpath: nil,
            originalPath: source.path,
            preferredName: skill.name)
        let sourceHash = try SkillFileUtilities.hashDirectory(resolved, fileManager: fileManager)

        skill.sourceType = .local
        skill.sourceRef = prepared.isArchive ? source.path : resolved.path
        let relative = relativePath(from: prepared.directory, to: resolved)
        skill.sourceSubpath = prepared.isArchive && !relative.isEmpty ? relative : nil
        skill.sourceBranch = nil
        skill.sourceRevision = nil
        skill.remoteRevision = sourceHash
        skill.sourceBookmarkData = sourceBookmarkData
        skill.updateStatus = sourceHash == skill.contentHash ? "current" : "update_available"
        skill.status = "ok"
        skill.updatedAt = Date()
        try store.upsertSkill(skill)
        audit("relink_source", skill: skill, detail: skill.sourceRef)
        return skill
    }

    @discardableResult
    public func detachSkillSource(id skillID: String) throws -> ManagedSkill {
        guard var skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        skill.sourceType = .local
        skill.sourceRef = nil
        skill.sourceSubpath = nil
        skill.sourceBranch = nil
        skill.sourceRevision = nil
        skill.remoteRevision = nil
        skill.sourceBookmarkData = nil
        skill.updateStatus = "unknown"
        skill.status = "ok"
        skill.updatedAt = Date()
        try store.upsertSkill(skill)
        audit("detach_source", skill: skill)
        return skill
    }

    public func scanLocalSkills() throws -> SkillScanResult {
        let managedPaths = Set(store.skills().flatMap { skill in
            [skill.centralPath] + skill.targets.map(\.targetPath)
        }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        var discovered: [DiscoveredSkillRecord] = []
        var toolsScanned = 0

        for adapter in catalog().adapters {
            let adapterAccess = SecurityScopedBookmarks.startAccessing(adapter.bookmarkData)
            defer { adapterAccess?.stop() }

            let additional = adapter.additionalExistingScanDirectories(
                home: homeDirectory,
                fileManager: fileManager)
            let installed = adapter.isInstalled(home: homeDirectory, fileManager: fileManager)
            if !installed && additional.isEmpty { continue }

            toolsScanned += 1
            var scanDirs: [URL] = []
            if installed {
                scanDirs.append(adapter.skillsDirectory(home: homeDirectory))
            }
            scanDirs.append(contentsOf: additional)

            for scanDir in uniqueURLs(scanDirs) where fileManager.fileExists(atPath: scanDir.path) {
                let skillDirs = SkillFileUtilities.collectSkillDirectories(
                    in: scanDir,
                    recursive: adapter.recursiveScan,
                    centralDirectory: skillsDirectory,
                    fileManager: fileManager)
                for skillDir in skillDirs {
                    let path = skillDir.standardizedFileURL.path
                    if managedPaths.contains(path) { continue }
                    let hash = try? SkillFileUtilities.hashDirectory(skillDir, fileManager: fileManager)
                    let name = SkillMetadataParser.inferSkillName(for: skillDir, fileManager: fileManager)
                    let importedID = matchImportedSkillID(path: path, fingerprint: hash)
                    discovered.append(DiscoveredSkillRecord(
                        tool: adapter.key,
                        foundPath: path,
                        nameGuess: name,
                        fingerprint: hash,
                        foundAt: modificationDate(for: skillDir),
                        importedSkillID: importedID,
                        bookmarkData: adapter.bookmarkData))
                }
            }
        }

        try store.replaceDiscovered(discovered)
        audit("scan", detail: "\(discovered.count) found")
        return SkillScanResult(
            toolsScanned: toolsScanned,
            skillsFound: discovered.count,
            groups: groupDiscovered(discovered))
    }

    @discardableResult
    public func syncSkill(id skillID: String,
                          toTool toolKey: String,
                          mode requestedMode: SkillTargetRecord.Mode = .symlink) throws -> SkillTargetRecord {
        guard var skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        guard let adapter = catalog().adapter(for: toolKey) else {
            throw SkillManagerError.missingTool(toolKey)
        }
        let adapterAccess = SecurityScopedBookmarks.startAccessing(adapter.bookmarkData)
        defer { adapterAccess?.stop() }

        let source = URL(fileURLWithPath: skill.centralPath)
        let currentHash = try? SkillFileUtilities.hashDirectory(source, fileManager: fileManager)
        let targetName = source.lastPathComponent.isEmpty ? skill.name : source.lastPathComponent
        let target = adapter.skillsDirectory(home: homeDirectory).appendingPathComponent(targetName)
        let existingRecord = skill.targets.first { $0.tool == toolKey }

        let actualMode = try SkillFileUtilities.syncSkill(
            source: source,
            target: target,
            mode: requestedMode,
            existingRecord: existingRecord,
            currentHash: currentHash,
            fileManager: fileManager)

        let record = SkillTargetRecord(
            id: existingRecord?.id ?? UUID().uuidString,
            skillID: skillID,
            tool: toolKey,
            targetPath: target.path,
            mode: actualMode,
            status: "ok",
            syncedAt: Date(),
            lastError: nil,
            sourceHash: currentHash)
        try store.upsertTarget(record)

        skill.contentHash = currentHash
        skill.updatedAt = Date()
        if let index = skill.targets.firstIndex(where: { $0.tool == toolKey }) {
            skill.targets[index] = record
        } else {
            skill.targets.append(record)
        }
        try store.upsertSkill(skill)
        audit("sync", skill: skill, tool: toolKey, detail: actualMode.rawValue)
        return record
    }

    public func unsyncSkill(id skillID: String, fromTool toolKey: String) throws {
        guard let skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        guard let target = skill.targets.first(where: { $0.tool == toolKey }) else {
            return
        }
        let adapterAccess = catalog()
            .adapter(for: toolKey)
            .flatMap { SecurityScopedBookmarks.startAccessing($0.bookmarkData) }
        defer { adapterAccess?.stop() }

        try SkillFileUtilities.removeTarget(
            at: URL(fileURLWithPath: target.targetPath),
            fileManager: fileManager)
        try store.deleteTarget(skillID: skillID, tool: toolKey)
        audit("unsync", skill: skill, tool: toolKey)
    }

    public func deleteSkill(id skillID: String, removeSyncedTargets: Bool = true) throws {
        guard let skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        if removeSyncedTargets {
            for target in skill.targets {
                let adapterAccess = catalog()
                    .adapter(for: target.tool)
                    .flatMap { SecurityScopedBookmarks.startAccessing($0.bookmarkData) }
                defer { adapterAccess?.stop() }

                try SkillFileUtilities.removeTarget(
                    at: URL(fileURLWithPath: target.targetPath),
                    fileManager: fileManager)
            }
        }
        try SkillFileUtilities.removeTarget(
            at: URL(fileURLWithPath: skill.centralPath),
            fileManager: fileManager)
        try store.deleteSkill(id: skillID)
        audit("delete", skill: skill, detail: removeSyncedTargets ? "removed synced targets" : nil)
    }

    @discardableResult
    public func setSkillTags(skillID: String, tags: [String]) throws -> ManagedSkill {
        guard var skill = store.skill(id: skillID) else {
            throw SkillManagerError.missingSkill(skillID)
        }
        skill.tags = normalizeTags(tags)
        skill.updatedAt = Date()
        try store.upsertSkill(skill)
        audit("set_tags", skill: skill, detail: skill.tags.joined(separator: ", "))
        return skill
    }

    public func addTag(_ tag: String, toSkillIDs skillIDs: [String]) throws {
        let normalized = normalizeTag(tag)
        guard let normalized else {
            throw SkillManagerError.invalidSkillName(tag)
        }
        for id in uniqueStrings(skillIDs) {
            guard var skill = store.skill(id: id) else {
                throw SkillManagerError.missingSkill(id)
            }
            skill.tags = normalizeTags(skill.tags + [normalized])
            skill.updatedAt = Date()
            try store.upsertSkill(skill)
            audit("tag_add", skill: skill, detail: normalized)
        }
    }

    public func removeTag(_ tag: String, fromSkillIDs skillIDs: [String]) throws {
        let normalized = normalizeTag(tag) ?? tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SkillManagerError.invalidSkillName(tag)
        }
        for id in uniqueStrings(skillIDs) {
            guard var skill = store.skill(id: id) else {
                throw SkillManagerError.missingSkill(id)
            }
            skill.tags.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
            skill.updatedAt = Date()
            try store.upsertSkill(skill)
            audit("tag_remove", skill: skill, detail: normalized)
        }
    }

    public func setToolEnabled(_ toolKey: String, enabled: Bool) throws {
        guard catalog().adapter(for: toolKey) != nil else {
            throw SkillManagerError.missingTool(toolKey)
        }
        var state = store.snapshot()
        if enabled {
            state.disabledToolKeys.remove(toolKey)
        } else {
            state.disabledToolKeys.insert(toolKey)
        }
        try store.setDisabledToolKeys(state.disabledToolKeys)
        audit(enabled ? "tool_enable" : "tool_disable", tool: toolKey)
    }

    public func addCustomTool(key: String,
                              displayName: String,
                              skillsDirectory: URL,
                              bookmarkData: Data? = nil,
                              projectRelativeSkillsDir: String? = nil,
                              category: SkillToolAdapter.Category = .coding) throws {
        guard let safeKey = SkillMetadataParser.sanitizeSkillName(key)?
            .lowercased()
            .replacingOccurrences(of: " ", with: "_"),
              !safeKey.isEmpty else {
            throw SkillManagerError.invalidSkillName(key)
        }

        var state = store.snapshot()
        state.customAdapters.removeAll { $0.key == safeKey }
        state.customAdapters.append(SkillToolAdapter(
            key: safeKey,
            displayName: displayName,
            relativeSkillsDir: "",
            relativeDetectDir: "",
            overrideSkillsDir: skillsDirectory.path,
            bookmarkData: bookmarkData,
            isCustom: true,
            projectRelativeSkillsDir: projectRelativeSkillsDir,
            category: category))
        try store.setCustomAdapters(state.customAdapters)
        audit("tool_custom_add", tool: safeKey, detail: skillsDirectory.path)
    }

    private struct GitCommandOutput {
        var stdout: String
        var stderr: String
        var exitCode: Int32

        var trimmedStdout: String {
            stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct ProcessCommandOutput {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private struct SourceSnapshot {
        var contentHash: String
        var revision: String?
    }

    private struct ResolvedSourceDirectory {
        var directory: URL
        var cleanupURL: URL?
        var access: SecurityScopedResourceAccess? = nil
    }

    private struct ClonedSkillsshSource {
        var cloneRoot: URL
        var sourceDirectory: URL
        var revision: String?
    }

    private func audit(_ action: String,
                       skill: ManagedSkill? = nil,
                       tool: String? = nil,
                       success: Bool = true,
                       detail: String? = nil) {
        store.appendAudit(SkillAuditEntry(
            action: action,
            skillID: skill?.id,
            skillName: skill?.name,
            tool: tool,
            success: success,
            detail: detail))
    }

    @discardableResult
    private func runGit(_ arguments: [String], allowFailure: Bool = false) throws -> GitCommandOutput {
        try runGit(in: skillsDirectory, arguments, allowFailure: allowFailure)
    }

    @discardableResult
    private func runGit(in directory: URL,
                        _ arguments: [String],
                        allowFailure: Bool = false) throws -> GitCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SkillManagerError.gitFailed("Failed to run git: \(error.localizedDescription)")
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = GitCommandOutput(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus)

        if output.exitCode != 0, !allowFailure {
            let message = [output.stderr, output.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "git \(arguments.joined(separator: " ")) failed."
            throw SkillManagerError.gitFailed(message)
        }

        return output
    }

    private func optionalGit(_ arguments: [String]) -> String? {
        optionalGit(in: skillsDirectory, arguments)
    }

    private func optionalGit(in directory: URL, _ arguments: [String]) -> String? {
        guard let output = try? runGit(in: directory, arguments) else { return nil }
        let trimmed = output.trimmedStdout
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private func runProcess(executable: String,
                            arguments: [String],
                            failurePrefix: String) throws -> ProcessCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SkillManagerError.archiveFailed("\(failurePrefix): \(error.localizedDescription)")
        }

        let output = ProcessCommandOutput(
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus)
        if output.exitCode != 0 {
            let message = [output.stderr, output.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? failurePrefix
            throw SkillManagerError.archiveFailed(message)
        }
        return output
    }

    private func projectAdapters() -> [SkillToolAdapter] {
        catalog().adapters.filter { adapter in
            !catalog().disabledToolKeys.contains(adapter.key) &&
                adapter.effectiveProjectRelativeSkillsDir?.isEmpty == false
        }
    }

    private func matchProjectSkill(path: String,
                                   name: String,
                                   fingerprint: String?,
                                   managedSkills: [ManagedSkill],
                                   projectTargets: [SkillProjectTargetRecord]) -> (skill: ManagedSkill?, status: String) {
        if let target = projectTargets.first(where: {
            URL(fileURLWithPath: $0.targetPath).standardizedFileURL.path == path
        }), let skill = managedSkills.first(where: { $0.id == target.skillID }) {
            if let fingerprint, fingerprint == skill.contentHash {
                return (skill, "in_sync")
            }
            return (skill, "diverged")
        }

        if let fingerprint,
           let skill = managedSkills.first(where: { $0.contentHash == fingerprint }) {
            return (skill, "in_sync")
        }

        let normalizedName = SkillMetadataParser.sanitizeSkillName(name)?.lowercased()
        if let normalizedName,
           let skill = managedSkills.first(where: { $0.name.lowercased() == normalizedName }) {
            return (skill, "diverged")
        }

        return (nil, "project_only")
    }

    private func resolveGitSkillSource(cloneRoot: URL, subdirectory: String?) throws -> URL {
        if let subdirectory = subdirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subdirectory.isEmpty {
            let source = cloneRoot.appendingPathComponent(subdirectory)
            guard SkillMetadataParser.isValidSkillDirectory(source, fileManager: fileManager) else {
                throw SkillManagerError.invalidSkillDirectory(source.path)
            }
            return source
        }

        if SkillMetadataParser.isValidSkillDirectory(cloneRoot, fileManager: fileManager) {
            return cloneRoot
        }

        let candidates = SkillFileUtilities.collectSkillDirectories(
            in: cloneRoot,
            recursive: true,
            centralDirectory: skillsDirectory,
            fileManager: fileManager)
        if candidates.count == 1, let source = candidates.first {
            return source
        }
        if candidates.isEmpty {
            throw SkillManagerError.invalidSkillDirectory(cloneRoot.path)
        }
        throw SkillManagerError.ambiguousArchive(cloneRoot.path)
    }

    private func sourceSnapshot(for skill: ManagedSkill) throws -> SourceSnapshot {
        switch skill.sourceType {
        case .local, .imported:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.invalidSkillDirectory(skill.centralPath)
            }
            let sourceAccess = SecurityScopedBookmarks.startAccessing(skill.sourceBookmarkData)
            defer { sourceAccess?.stop() }

            let sourceURL = URL(fileURLWithPath: sourceRef)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw SkillManagerError.invalidSkillDirectory(sourceRef)
            }
            let prepared = try prepareLocalImportRoot(sourceURL)
            defer {
                if let cleanupURL = prepared.cleanupURL {
                    try? fileManager.removeItem(at: cleanupURL)
                }
            }
            let source = try resolveLocalSkillSource(
                root: prepared.directory,
                subpath: skill.sourceSubpath,
                originalPath: sourceRef)
            return SourceSnapshot(
                contentHash: try SkillFileUtilities.hashDirectory(source, fileManager: fileManager),
                revision: nil)
        case .git:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.gitFailed("Git skill has no source repository.")
            }
            let tmpRoot = rootDirectory.appendingPathComponent("tmp")
            try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
            let cloneRoot = tmpRoot.appendingPathComponent("git-check-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: cloneRoot) }
            try runGit(in: tmpRoot, ["clone", sourceRef, cloneRoot.path])
            if let branch = skill.sourceBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
               !branch.isEmpty {
                try runGit(in: cloneRoot, ["checkout", branch])
            }
            let source = try resolveGitSkillSource(
                cloneRoot: cloneRoot,
                subdirectory: skill.sourceSubpath)
            return SourceSnapshot(
                contentHash: try SkillFileUtilities.hashDirectory(source, fileManager: fileManager),
                revision: optionalGit(in: cloneRoot, ["rev-parse", "HEAD"]))
        case .skillssh:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.gitFailed("skills.sh skill has no source reference.")
            }
            let checkout = try cloneSkillsshSource(
                sourceRef: sourceRef,
                branch: skill.sourceBranch,
                subpath: skill.sourceSubpath,
                prefix: "skillssh-check")
            defer { try? fileManager.removeItem(at: checkout.cloneRoot) }
            return SourceSnapshot(
                contentHash: try SkillFileUtilities.hashDirectory(
                    checkout.sourceDirectory,
                    fileManager: fileManager),
                revision: checkout.revision)
        }
    }

    private func resolveSourceDirectoryForPreview(_ skill: ManagedSkill) throws -> ResolvedSourceDirectory {
        switch skill.sourceType {
        case .local, .imported:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.invalidSkillDirectory(skill.centralPath)
            }
            let sourceAccess = SecurityScopedBookmarks.startAccessing(skill.sourceBookmarkData)

            let prepared = try prepareLocalImportRoot(URL(fileURLWithPath: sourceRef))
            do {
                let source = try resolveLocalSkillSource(
                    root: prepared.directory,
                    subpath: skill.sourceSubpath,
                    originalPath: sourceRef,
                    preferredName: skill.name)
                return ResolvedSourceDirectory(
                    directory: source,
                    cleanupURL: prepared.cleanupURL,
                    access: sourceAccess)
            } catch {
                sourceAccess?.stop()
                if let cleanupURL = prepared.cleanupURL {
                    try? fileManager.removeItem(at: cleanupURL)
                }
                throw error
            }
        case .git:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.gitFailed("Git skill has no source repository.")
            }
            let tmpRoot = rootDirectory.appendingPathComponent("tmp")
            try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
            let cloneRoot = tmpRoot.appendingPathComponent("git-diff-\(UUID().uuidString)")
            do {
                try runGit(in: tmpRoot, ["clone", sourceRef, cloneRoot.path])
                if let branch = skill.sourceBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !branch.isEmpty {
                    try runGit(in: cloneRoot, ["checkout", branch])
                }
                let source = try resolveGitSkillSource(
                    cloneRoot: cloneRoot,
                    subdirectory: skill.sourceSubpath)
                return ResolvedSourceDirectory(directory: source, cleanupURL: cloneRoot)
            } catch {
                try? fileManager.removeItem(at: cloneRoot)
                throw error
            }
        case .skillssh:
            guard let sourceRef = skill.sourceRef else {
                throw SkillManagerError.gitFailed("skills.sh skill has no source reference.")
            }
            let checkout = try cloneSkillsshSource(
                sourceRef: sourceRef,
                branch: skill.sourceBranch,
                subpath: skill.sourceSubpath,
                prefix: "skillssh-diff")
            return ResolvedSourceDirectory(
                directory: checkout.sourceDirectory,
                cleanupURL: checkout.cloneRoot)
        }
    }

    private func cloneSkillsshSource(sourceRef: String,
                                     branch: String?,
                                     subpath: String?,
                                     prefix: String) throws -> ClonedSkillsshSource {
        let parsed = try parseSkillsshSourceRef(sourceRef)
        let tmpRoot = rootDirectory.appendingPathComponent("tmp")
        try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let cloneRoot = tmpRoot.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        do {
            try runGit(in: tmpRoot, ["clone", parsed.repositoryURL, cloneRoot.path])
            if let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines),
               !branch.isEmpty {
                try runGit(in: cloneRoot, ["checkout", branch])
            }
            let sourceDirectory = try resolveSkillsshSource(
                cloneRoot: cloneRoot,
                skillID: parsed.skillID,
                subdirectory: subpath)
            return ClonedSkillsshSource(
                cloneRoot: cloneRoot,
                sourceDirectory: sourceDirectory,
                revision: optionalGit(in: cloneRoot, ["rev-parse", "HEAD"]))
        } catch {
            try? fileManager.removeItem(at: cloneRoot)
            throw error
        }
    }

    private func parseSkillsshSourceRef(_ sourceRef: String) throws -> (repoSource: String, skillID: String, repositoryURL: String) {
        let parts = sourceRef.split(separator: "/").map(String.init)
        guard parts.count >= 3, let skillID = parts.last else {
            throw SkillManagerError.gitFailed("Invalid skills.sh source reference: \(sourceRef)")
        }
        let repoSource = parts.dropLast().joined(separator: "/")
        return (repoSource, skillID, skillsshRepositoryURL(repoSource: repoSource))
    }

    private func skillsshRepositoryURL(repoSource: String) -> String {
        "https://github.com/\(repoSource).git"
    }

    private func resolveSkillsshSource(cloneRoot: URL,
                                       skillID: String,
                                       subdirectory: String?) throws -> URL {
        if let subdirectory = subdirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subdirectory.isEmpty {
            let source = cloneRoot.appendingPathComponent(subdirectory)
            guard SkillMetadataParser.isValidSkillDirectory(source, fileManager: fileManager) else {
                throw SkillManagerError.invalidSkillDirectory(source.path)
            }
            return source
        }

        let normalizedSkillID = SkillMetadataParser.sanitizeSkillName(skillID)?.lowercased() ??
            skillID.lowercased()
        let candidates = SkillFileUtilities.collectSkillDirectories(
            in: cloneRoot,
            recursive: true,
            centralDirectory: skillsDirectory,
            fileManager: fileManager)
        if let exact = candidates.first(where: {
            $0.lastPathComponent.lowercased() == normalizedSkillID ||
                SkillMetadataParser.inferSkillName(for: $0, fileManager: fileManager).lowercased() == normalizedSkillID
        }) {
            return exact
        }
        if candidates.count == 1, let source = candidates.first {
            return source
        }
        if candidates.isEmpty {
            throw SkillManagerError.invalidSkillDirectory(cloneRoot.path)
        }
        throw SkillManagerError.ambiguousArchive(cloneRoot.path)
    }

    private func buildSourceDiffEntries(original: URL,
                                        updated: URL,
                                        maxFileBytes: Int,
                                        limit: Int) throws -> [SkillSourceDiffEntry] {
        let originalFiles = try SkillFileUtilities.contentFileMap(in: original, fileManager: fileManager)
        let updatedFiles = try SkillFileUtilities.contentFileMap(in: updated, fileManager: fileManager)
        let paths = Array(Set(originalFiles.keys).union(updatedFiles.keys)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        var entries: [SkillSourceDiffEntry] = []
        for path in paths {
            guard entries.count < limit else { break }
            let originalURL = originalFiles[path]
            let updatedURL = updatedFiles[path]
            let originalData = originalURL.flatMap { try? Data(contentsOf: $0) }
            let updatedData = updatedURL.flatMap { try? Data(contentsOf: $0) }

            let status: String
            switch (originalData, updatedData) {
            case (nil, nil):
                continue
            case (nil, _):
                status = "added"
            case (_, nil):
                status = "removed"
            case (let lhs?, let rhs?) where lhs == rhs:
                continue
            default:
                status = "modified"
            }

            let originalClass = classifyDiffData(originalData, maxFileBytes: maxFileBytes)
            let updatedClass = classifyDiffData(updatedData, maxFileBytes: maxFileBytes)
            entries.append(SkillSourceDiffEntry(
                relativePath: path,
                status: status,
                originalKind: originalClass.kind,
                updatedKind: updatedClass.kind,
                originalContent: originalClass.content,
                updatedContent: updatedClass.content))
        }
        return entries
    }

    private func classifyDiffData(_ data: Data?, maxFileBytes: Int) -> (kind: String, content: String?) {
        guard let data else { return ("missing", nil) }
        if data.count > maxFileBytes { return ("too_large", nil) }
        if data.contains(0) { return ("binary", nil) }
        guard let content = String(data: data, encoding: .utf8) else {
            return ("binary", nil)
        }
        return ("text", content)
    }

    private func replaceCentralSkill(_ skill: ManagedSkill,
                                     withSource source: URL,
                                     sourceRevision: String?) throws -> ManagedSkill {
        let destination = URL(fileURLWithPath: skill.centralPath)
        let tempRoot = rootDirectory.appendingPathComponent("tmp")
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let staged = tempRoot.appendingPathComponent("refresh-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staged) }

        try SkillFileUtilities.copySkillDirectory(
            from: source,
            to: staged,
            fileManager: fileManager)

        if fileManager.fileExists(atPath: destination.path) {
            try SkillFileUtilities.removeTarget(at: destination, fileManager: fileManager)
        }
        try fileManager.moveItem(at: staged, to: destination)

        let metadata = SkillMetadataParser.parse(directory: destination, fileManager: fileManager)
        let hash = try SkillFileUtilities.hashDirectory(destination, fileManager: fileManager)
        var updated = skill
        if let name = metadata.name.flatMap(SkillMetadataParser.sanitizeSkillName) {
            updated.name = name
        }
        updated.description = metadata.description
        updated.contentHash = hash
        updated.sourceRevision = sourceRevision
        updated.remoteRevision = sourceRevision
        updated.updateStatus = "current"
        updated.lastCheckedAt = Date()
        updated.lastCheckError = nil
        updated.updatedAt = Date()
        try store.upsertSkill(updated)

        let previousTargets = skill.targets
        for target in previousTargets {
            _ = try syncSkill(id: skill.id, toTool: target.tool, mode: target.mode)
        }
        let finalSkill = store.skill(id: skill.id) ?? updated
        audit("refresh", skill: finalSkill, detail: sourceRevision ?? finalSkill.remoteRevision)
        return finalSkill
    }

    private func skillsForBundleExport(_ skillIDs: [String]?) throws -> [ManagedSkill] {
        guard let skillIDs, !skillIDs.isEmpty else {
            return listSkills()
        }
        return try uniqueStrings(skillIDs).map { id in
            guard let skill = store.skill(id: id) else {
                throw SkillManagerError.missingSkill(id)
            }
            return skill
        }
    }

    private func bundleManifestSkill(for skill: ManagedSkill,
                                     directoryName: String) -> SkillBundleManifestSkill {
        SkillBundleManifestSkill(
            directoryName: directoryName,
            name: skill.name,
            description: skill.description,
            sourceType: skill.sourceType,
            sourceRef: skill.sourceRef,
            sourceSubpath: skill.sourceSubpath,
            sourceBranch: skill.sourceBranch,
            sourceRevision: skill.sourceRevision,
            remoteRevision: skill.remoteRevision,
            updateStatus: skill.updateStatus,
            tags: skill.tags,
            contentHash: skill.contentHash)
    }

    private func uniqueBundleDirectoryName(for skill: ManagedSkill,
                                           used: inout Set<String>) -> String {
        let centralName = URL(fileURLWithPath: skill.centralPath).lastPathComponent
        let base = SkillMetadataParser.sanitizeSkillName(skill.name) ??
            SkillMetadataParser.sanitizeSkillName(centralName) ??
            "skill"
        for index in 1..<10_000 {
            let candidate = index == 1 ? base : "\(base)-\(index)"
            if used.insert(candidate).inserted {
                return candidate
            }
        }
        let fallback = "\(base)-\(UUID().uuidString)"
        used.insert(fallback)
        return fallback
    }

    private func findBundleManifest(in root: URL) -> URL? {
        let manifestName = "skill-bundle.json"
        let direct = root.appendingPathComponent(manifestName)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: direct.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return direct
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == manifestName {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    private func installBundleManifestSkill(_ entry: SkillBundleManifestSkill,
                                            skillsRoot: URL,
                                            extraTags: [String]) throws -> ManagedSkill? {
        let source = skillsRoot.appendingPathComponent(entry.directoryName)
        let rootPath = skillsRoot.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        guard sourcePath.hasPrefix(rootPath + "/"),
              SkillMetadataParser.isValidSkillDirectory(source, fileManager: fileManager) else {
            return nil
        }

        let mergedTags = orderedUnion(normalizeTags(entry.tags), extraTags)
        let result = try installLocalSkill(
            source: source,
            name: entry.name,
            sourceType: entry.sourceType,
            sourceRef: entry.sourceRef,
            sourceSubpath: entry.sourceSubpath,
            sourceBranch: entry.sourceBranch,
            sourceRevision: entry.sourceRevision,
            remoteRevision: entry.remoteRevision,
            updateStatus: entry.updateStatus.isEmpty ? "unknown" : entry.updateStatus,
            tags: mergedTags)

        var skill = result.skill
        skill.sourceType = entry.sourceType
        skill.sourceRef = entry.sourceRef
        skill.sourceSubpath = entry.sourceSubpath
        skill.sourceBranch = entry.sourceBranch
        skill.sourceRevision = entry.sourceRevision
        skill.remoteRevision = entry.remoteRevision
        skill.updateStatus = entry.updateStatus.isEmpty ? "unknown" : entry.updateStatus
        skill.tags = orderedUnion(skill.tags, mergedTags)
        skill.updatedAt = Date()
        try store.upsertSkill(skill)
        return skill
    }

    private func prepareLocalSource(_ source: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return source
        }
        throw SkillManagerError.unsupportedArchive(source.path)
    }

    private struct PreparedLocalImportRoot {
        var directory: URL
        var cleanupURL: URL?
        var isArchive: Bool
    }

    private func prepareLocalImportRoot(_ source: URL) throws -> PreparedLocalImportRoot {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return PreparedLocalImportRoot(directory: source, cleanupURL: nil, isArchive: false)
        }
        let ext = source.pathExtension.lowercased()
        guard ext == "zip" || ext == "skill" else {
            throw SkillManagerError.unsupportedArchive(source.path)
        }
        let directory = try extractArchive(source)
        return PreparedLocalImportRoot(directory: directory, cleanupURL: directory, isArchive: true)
    }

    private func extractArchive(_ source: URL) throws -> URL {
        let tmpRoot = rootDirectory.appendingPathComponent("tmp")
        try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let destination = tmpRoot.appendingPathComponent("archive-\(UUID().uuidString)")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try runProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", source.path, destination.path],
                failurePrefix: "Failed to extract archive \(source.path)")
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func resolveLocalSkillSource(root: URL,
                                         subpath: String?,
                                         originalPath: String,
                                         preferredName: String? = nil) throws -> URL {
        if let subpath = subpath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subpath.isEmpty {
            let source = root.appendingPathComponent(subpath)
            guard SkillMetadataParser.isValidSkillDirectory(source, fileManager: fileManager) else {
                throw SkillManagerError.invalidSkillDirectory(source.path)
            }
            return source
        }

        if SkillMetadataParser.isValidSkillDirectory(root, fileManager: fileManager) {
            return root
        }

        let candidates = SkillFileUtilities.collectSkillDirectories(
            in: root,
            recursive: true,
            centralDirectory: skillsDirectory,
            fileManager: fileManager)
        if candidates.count == 1, let source = candidates.first {
            return source
        }
        if let preferredName,
           let normalizedName = SkillMetadataParser.sanitizeSkillName(preferredName)?.lowercased(),
           let matched = candidates.first(where: {
               SkillMetadataParser.inferSkillName(for: $0, fileManager: fileManager).lowercased() == normalizedName
           }) {
            return matched
        }
        if candidates.isEmpty {
            throw SkillManagerError.invalidSkillDirectory(originalPath)
        }
        throw SkillManagerError.ambiguousArchive(originalPath)
    }

    private func ensureSkillsExist(_ skillIDs: [String]) throws {
        for id in uniqueStrings(skillIDs) where store.skill(id: id) == nil {
            throw SkillManagerError.missingSkill(id)
        }
    }

    private func orderedPresetSkills(_ skillIDs: [String]) -> [SkillPresetSkill] {
        uniqueStrings(skillIDs).enumerated().map { index, skillID in
            SkillPresetSkill(skillID: skillID, order: index)
        }
    }

    private func normalizePresetOrder(_ skills: [SkillPresetSkill]) -> [SkillPresetSkill] {
        skills
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { index, item in
                var copy = item
                copy.order = index
                return copy
            }
    }

    private func normalizeTag(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: ",", with: " ")
    }

    private func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags {
            guard let normalized = normalizeTag(tag) else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                out.append(normalized)
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }

    private func uniqueSkillDestination(parent: URL,
                                        sanitizedName: String,
                                        source: URL) throws -> URL {
        let sourceHash = try SkillFileUtilities.hashDirectory(source, fileManager: fileManager)
        for i in 1..<10_000 {
            let candidateName = i == 1 ? sanitizedName : "\(sanitizedName)-\(i)"
            let candidate = parent.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            if (try? SkillFileUtilities.hashDirectory(candidate, fileManager: fileManager)) == sourceHash {
                return candidate
            }
        }
        return parent.appendingPathComponent(sanitizedName)
    }

    private func relativePath(from root: URL, to file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return file.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func gitScanRoot(cloneRoot: URL, subdirectory: String?) -> URL {
        guard let subdirectory,
              !subdirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cloneRoot
        }
        return cloneRoot.appendingPathComponent(subdirectory)
    }

    private func gitSkillCandidates(in scanRoot: URL) throws -> [URL] {
        let candidates: [URL]
        if SkillMetadataParser.isValidSkillDirectory(scanRoot, fileManager: fileManager) {
            candidates = [scanRoot]
        } else {
            candidates = SkillFileUtilities.collectSkillDirectories(
                in: scanRoot,
                recursive: true,
                centralDirectory: skillsDirectory,
                fileManager: fileManager)
                .sorted { lhs, rhs in
                    lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
                }
        }
        guard !candidates.isEmpty else {
            throw SkillManagerError.invalidSkillDirectory(scanRoot.path)
        }
        return candidates
    }

    private func gitPreviewPath(scanRoot: URL, skillDirectory: URL) -> String {
        normalizeGitPreviewPath(relativePath(from: scanRoot, to: skillDirectory))
    }

    private func normalizeGitPreviewPath(_ path: String) -> String {
        let normalized = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "." : normalized
    }

    private func matchImportedSkillID(path: String, fingerprint: String?) -> String? {
        let skills = store.skills()
        if let direct = skills.first(where: { skill in
            skill.sourceRef == path ||
                URL(fileURLWithPath: skill.centralPath).standardizedFileURL.path == path
        }) {
            return direct.id
        }
        if let fingerprint,
           let hashMatch = skills.first(where: { $0.contentHash == fingerprint }) {
            return hashMatch.id
        }
        return nil
    }

    private func groupDiscovered(_ records: [DiscoveredSkillRecord]) -> [DiscoveredSkillGroup] {
        var groups: [String: DiscoveredSkillGroup] = [:]

        for record in records {
            let name = record.nameGuess ?? "unknown"
            let key = record.fingerprint.map { "fp:\(name):\($0)" } ??
                "path:\(name):\(record.foundPath)"
            var group = groups[key] ?? DiscoveredSkillGroup(
                name: name,
                fingerprint: record.fingerprint,
                locations: [],
                imported: false,
                foundAt: record.foundAt)
            group.imported = group.imported || record.importedSkillID != nil
            if record.foundAt < group.foundAt { group.foundAt = record.foundAt }
            group.locations.append(DiscoveredSkillGroup.Location(
                id: record.id,
                tool: record.tool,
                foundPath: record.foundPath))
            groups[key] = group
        }

        return groups.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func modificationDate(for url: URL) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(url) }
        }
        return out
    }

    private func orderedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in lhs + rhs where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}
