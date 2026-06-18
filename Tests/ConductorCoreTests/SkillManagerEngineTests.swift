import XCTest
@testable import ConductorCore

final class SkillManagerEngineTests: XCTestCase {
    private func makeTempDir(_ name: String = "skill-manager") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSkill(at directory: URL,
                           name: String,
                           description: String = "Useful skill") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description)
        ---
        # \(name)
        """.write(to: directory.appendingPathComponent("SKILL.md"),
                  atomically: true,
                  encoding: .utf8)
    }

    func testDefaultCatalogIncludesExpandedAgentSet() {
        let catalog = SkillToolCatalog()
        XCTAssertGreaterThanOrEqual(catalog.adapters.count, 40)
        XCTAssertNotNil(catalog.adapter(for: "claude_code"))
        XCTAssertNotNil(catalog.adapter(for: "codex"))
        XCTAssertNotNil(catalog.adapter(for: "gemini_cli"))
        XCTAssertNotNil(catalog.adapter(for: "github_copilot"))
        XCTAssertNotNil(catalog.adapter(for: "windsurf"))
        XCTAssertEqual(catalog.adapter(for: "openclaw")?.category, .lobster)
        XCTAssertEqual(catalog.adapter(for: "codex")?.additionalScanDirs, [".agents/skills"])
    }

    func testInstallLocalSkillAndSyncToCustomToolByCopy() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        try makeSkill(at: source, name: "db-tools", description: "Database helpers")

        let engine = try SkillManagerEngine(
            rootDirectory: root.appendingPathComponent("manager"),
            homeDirectory: home)
        let toolDir = root.appendingPathComponent("custom-agent/skills")
        try engine.addCustomTool(
            key: "test agent",
            displayName: "Test Agent",
            skillsDirectory: toolDir)

        let install = try engine.installLocalSkill(source: source)
        XCTAssertEqual(install.skill.name, "db-tools")
        XCTAssertEqual(install.skill.description, "Database helpers")
        XCTAssertTrue(FileManager.default.fileExists(atPath: install.skill.centralPath))

        let target = try engine.syncSkill(
            id: install.skill.id,
            toTool: "test_agent",
            mode: .copy)

        XCTAssertEqual(target.mode, .copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.targetPath))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: target.targetPath)
                .appendingPathComponent("SKILL.md")
                .path))

        try engine.unsyncSkill(id: install.skill.id, fromTool: "test_agent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.targetPath))
    }

    func testScanDiscoversAndImportsExternalSkill() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = try SkillManagerEngine(
            rootDirectory: root.appendingPathComponent("manager"),
            homeDirectory: home)
        let toolDir = root.appendingPathComponent("external-agent/skills")
        try engine.addCustomTool(
            key: "external",
            displayName: "External",
            skillsDirectory: toolDir)

        let existing = toolDir.appendingPathComponent("review")
        try makeSkill(at: existing, name: "review", description: "Review code")

        let scan = try engine.scanLocalSkills()
        XCTAssertEqual(scan.skillsFound, 1)
        XCTAssertEqual(scan.groups.first?.name, "review")
        XCTAssertEqual(scan.groups.first?.locations.first?.tool, "external")

        let recordID = try XCTUnwrap(scan.groups.first?.locations.first?.id)
        let imported = try engine.importDiscoveredSkill(recordID: recordID)
        XCTAssertEqual(imported.name, "review")
        XCTAssertEqual(engine.listSkills().count, 1)
    }

    func testPresetAppliesAndRemovesSkillsAcrossTools() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceA = root.appendingPathComponent("source/db")
        let sourceB = root.appendingPathComponent("source/review")
        try makeSkill(at: sourceA, name: "db-tools")
        try makeSkill(at: sourceB, name: "review")

        let engine = try SkillManagerEngine(
            rootDirectory: root.appendingPathComponent("manager"),
            homeDirectory: home)
        let toolDir = root.appendingPathComponent("agent/skills")
        try engine.addCustomTool(
            key: "preset agent",
            displayName: "Preset Agent",
            skillsDirectory: toolDir)

        let skillA = try engine.installLocalSkill(source: sourceA).skill
        let skillB = try engine.installLocalSkill(source: sourceB).skill
        let preset = try engine.createPreset(
            name: "Backend",
            skillIDs: [skillA.id, skillB.id])

        XCTAssertEqual(engine.listPresets().first?.skills.count, 2)

        let records = try engine.applyPreset(
            id: preset.id,
            toTools: ["preset_agent"],
            mode: .copy)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: toolDir.appendingPathComponent("db-tools/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: toolDir.appendingPathComponent("review/SKILL.md").path))

        let summary = engine.presetSummaries(toolKeys: ["preset_agent"]).first
        XCTAssertEqual(summary?.skillCount, 2)
        XCTAssertEqual(summary?.syncedPairs, 2)
        XCTAssertEqual(summary?.totalPairs, 2)

        try engine.removePreset(id: preset.id, fromTools: ["preset_agent"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: toolDir.appendingPathComponent("db-tools").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: toolDir.appendingPathComponent("review").path))
    }

    func testProjectWorkspaceSyncsAndReadsProjectSkills() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        try makeSkill(at: source, name: "db-tools")
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let engine = try SkillManagerEngine(
            rootDirectory: root.appendingPathComponent("manager"),
            homeDirectory: home)
        try engine.addCustomTool(
            key: "project agent",
            displayName: "Project Agent",
            skillsDirectory: root.appendingPathComponent("global-agent/skills"),
            projectRelativeSkillsDir: ".project-agent/skills")

        let skill = try engine.installLocalSkill(source: source).skill
        let project = try engine.addProject(path: projectRoot)

        let target = try engine.syncSkillToProject(
            skillID: skill.id,
            projectID: project.id,
            toolKey: "project_agent",
            mode: .copy)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: target.targetPath)
                .appendingPathComponent("SKILL.md")
                .path))

        let projectSkills = engine.readProjectSkills(projectID: project.id)
        XCTAssertEqual(projectSkills.count, 1)
        XCTAssertEqual(projectSkills.first?.name, "db-tools")
        XCTAssertEqual(projectSkills.first?.tool, "project_agent")
        XCTAssertEqual(projectSkills.first?.syncStatus, "in_sync")
        XCTAssertEqual(projectSkills.first?.centerSkillID, skill.id)

        try engine.unsyncSkillFromProject(
            skillID: skill.id,
            projectID: project.id,
            toolKey: "project_agent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.targetPath))
    }

    func testSkillTagsCanBeAddedAndRemovedInBatch() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceA = root.appendingPathComponent("source/db")
        let sourceB = root.appendingPathComponent("source/review")
        try makeSkill(at: sourceA, name: "db-tools")
        try makeSkill(at: sourceB, name: "review")

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let skillA = try engine.installLocalSkill(source: sourceA).skill
        let skillB = try engine.installLocalSkill(source: sourceB).skill

        try engine.addTag("backend", toSkillIDs: [skillA.id, skillB.id])
        XCTAssertEqual(engine.listSkills().flatMap(\.tags), ["backend", "backend"])

        try engine.removeTag("backend", fromSkillIDs: [skillA.id])
        let tagsByID = Dictionary(uniqueKeysWithValues: engine.listSkills().map { ($0.id, $0.tags) })
        XCTAssertEqual(tagsByID[skillA.id], [])
        XCTAssertEqual(tagsByID[skillB.id], ["backend"])
    }

    func testReadsSkillDocumentAndFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        try makeSkill(at: source, name: "db-tools")
        try "extra".write(to: source.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let skill = try engine.installLocalSkill(source: source).skill

        let document = try engine.readSkillDocument(skillID: skill.id)
        XCTAssertEqual(document.filename, "SKILL.md")
        XCTAssertTrue(document.content.contains("db-tools"))

        let files = try engine.listSkillFiles(skillID: skill.id)
        XCTAssertTrue(files.contains { $0.relativePath == "SKILL.md" })
        XCTAssertTrue(files.contains { $0.relativePath == "notes.md" })
    }

    func testInstallLocalSkillsImportsNestedParentDirectory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceRoot = root.appendingPathComponent("skill-pack")
        try makeSkill(at: sourceRoot.appendingPathComponent("backend/db"), name: "db-tools")
        try makeSkill(at: sourceRoot.appendingPathComponent("review"), name: "review")

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let results = try engine.installLocalSkills(source: sourceRoot)
        XCTAssertEqual(Set(results.map(\.skill.name)), Set(["db-tools", "review"]))
        XCTAssertEqual(engine.listSkills().count, 2)
        XCTAssertTrue(engine.listSkills().allSatisfy { $0.sourceRef?.contains("skill-pack") == true })
    }

    func testRefreshLocalSkillFromSourceUpdatesCentralCopy() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        try makeSkill(at: source, name: "db-tools", description: "Before")

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let skill = try engine.installLocalSkill(source: source).skill

        try makeSkill(at: source, name: "db-tools", description: "After")
        let refreshed = try engine.refreshSkillFromSource(id: skill.id)
        XCTAssertEqual(refreshed.description, "After")

        let document = try engine.readSkillDocument(skillID: skill.id)
        XCTAssertTrue(document.content.contains("After"))
    }

    func testCheckSkillUpdateMarksLocalChanges() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        try makeSkill(at: source, name: "db-tools", description: "Before")

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let skill = try engine.installLocalSkill(source: source).skill

        let current = try engine.checkSkillUpdate(id: skill.id)
        XCTAssertEqual(current.updateStatus, "current")

        try makeSkill(at: source, name: "db-tools", description: "After")
        let changed = try engine.checkSkillUpdate(id: skill.id)
        XCTAssertEqual(changed.updateStatus, "update_available")
        XCTAssertNotNil(changed.remoteRevision)
    }

    func testRelinkAndDetachSkillSource() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        let replacement = root.appendingPathComponent("replacement/db")
        try makeSkill(at: source, name: "db-tools", description: "Before")
        try makeSkill(at: replacement, name: "db-tools", description: "After")

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let skill = try engine.installLocalSkill(source: source).skill

        let relinked = try engine.relinkSkillSource(id: skill.id, source: replacement)
        XCTAssertEqual(relinked.sourceRef, replacement.path)
        XCTAssertEqual(relinked.updateStatus, "update_available")

        let detached = try engine.detachSkillSource(id: skill.id)
        XCTAssertNil(detached.sourceRef)
        XCTAssertEqual(detached.updateStatus, "unknown")
    }

    func testReadsSourceDiffForChangedLocalSkill() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        try makeSkill(at: source, name: "db-tools", description: "Before")

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let skill = try engine.installLocalSkill(source: source).skill

        try makeSkill(at: source, name: "db-tools", description: "After")
        let diff = try engine.readSkillSourceDiff(skillID: skill.id)
        XCTAssertEqual(diff.entries.first?.relativePath, "SKILL.md")
        XCTAssertEqual(diff.entries.first?.status, "modified")
        XCTAssertTrue(diff.entries.first?.updatedContent?.contains("After") == true)
    }

    func testParsesSkillsShNextDataPayload() {
        let html = """
        <html>
        <script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"initialSkills":[{"source":"antfu/skills","skillId":"vite","name":"vite","installs":152}]}}}
        </script>
        </html>
        """
        let skills = SkillsshClient.parseLeaderboardHTML(html)
        XCTAssertEqual(skills.first?.id, "antfu/skills/vite")
        XCTAssertEqual(skills.first?.skillID, "vite")
        XCTAssertEqual(skills.first?.installs, 152)
    }

    func testInstallGitSkillsImportsMultipleSkillDirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try makeSkill(at: repo.appendingPathComponent("skills/db"), name: "db-tools")
        try makeSkill(at: repo.appendingPathComponent("skills/review"), name: "review")
        try Process.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["git", "-C", repo.path, "init"]).waitUntilExit()
        try Process.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["git", "-C", repo.path, "add", "."]).waitUntilExit()
        try Process.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "git", "-C", repo.path,
            "-c", "user.name=Test",
            "-c", "user.email=test@example.com",
            "commit", "-m", "init"
        ]).waitUntilExit()

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let results = try engine.installGitSkills(repositoryURL: repo.path)
        XCTAssertEqual(Set(results.map(\.skill.name)), Set(["db-tools", "review"]))
        XCTAssertTrue(results.allSatisfy { $0.skill.sourceType == .git })
        XCTAssertTrue(results.allSatisfy { $0.skill.sourceSubpath?.hasPrefix("skills/") == true })
    }

    func testPreviewGitSkillsAndInstallSelectedSubpath() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try makeSkill(at: repo.appendingPathComponent("skills/db"), name: "db-tools", description: "Database helpers")
        try makeSkill(at: repo.appendingPathComponent("skills/review"), name: "review", description: "Review helper")
        try Process.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["git", "-C", repo.path, "init"]).waitUntilExit()
        try Process.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["git", "-C", repo.path, "add", "."]).waitUntilExit()
        try Process.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "git", "-C", repo.path,
            "-c", "user.name=Test",
            "-c", "user.email=test@example.com",
            "commit", "-m", "init"
        ]).waitUntilExit()

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let preview = try engine.previewGitSkills(repositoryURL: repo.path, subdirectory: "skills")
        XCTAssertEqual(preview.map(\.relativePath), ["db", "review"])
        XCTAssertEqual(preview.first { $0.relativePath == "review" }?.description, "Review helper")

        let results = try engine.installGitSkills(
            repositoryURL: repo.path,
            subdirectory: "skills",
            selectedSubpaths: ["review"])
        XCTAssertEqual(results.map(\.skill.name), ["review"])
        XCTAssertEqual(results.first?.skill.sourceSubpath, "skills/review")
    }

    func testExportsAndImportsSkillBundleWithManifest() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        try makeSkill(at: source, name: "db-tools", description: "Database helpers")

        let sourceEngine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager-source"))
        let original = try sourceEngine.installLocalSkill(source: source, tags: ["backend"]).skill
        let bundle = root.appendingPathComponent("skills-bundle.zip")
        let exported = try sourceEngine.exportSkillBundle(skillIDs: [original.id], to: bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))

        let importEngine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager-import"))
        let result = try importEngine.importSkillBundle(source: exported, tags: ["shared"])
        let imported = try XCTUnwrap(result.installed.first)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(imported.name, "db-tools")
        XCTAssertEqual(imported.description, "Database helpers")
        XCTAssertEqual(imported.sourceType, .local)
        XCTAssertEqual(imported.sourceRef, source.path)
        XCTAssertEqual(Set(imported.tags), Set(["backend", "shared"]))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: imported.centralPath)
                .appendingPathComponent("SKILL.md")
                .path))
    }

    func testSkillActionsWriteAuditEntries() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source/db")
        try makeSkill(at: source, name: "db-tools")

        let engine = try SkillManagerEngine(
            rootDirectory: root.appendingPathComponent("manager"),
            homeDirectory: home)
        try engine.addCustomTool(
            key: "audit agent",
            displayName: "Audit Agent",
            skillsDirectory: root.appendingPathComponent("audit-agent/skills"))

        let skill = try engine.installLocalSkill(source: source).skill
        _ = try engine.syncSkill(id: skill.id, toTool: "audit_agent", mode: .copy)
        try engine.addTag("backend", toSkillIDs: [skill.id])

        let actions = Set(engine.listAudit(limit: 20).map(\.action))
        XCTAssertTrue(actions.contains("install"))
        XCTAssertTrue(actions.contains("sync"))
        XCTAssertTrue(actions.contains("tag_add"))
    }

    func testMoveSkillInPresetReordersItems() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceA = root.appendingPathComponent("source/a")
        let sourceB = root.appendingPathComponent("source/b")
        let sourceC = root.appendingPathComponent("source/c")
        try makeSkill(at: sourceA, name: "alpha")
        try makeSkill(at: sourceB, name: "bravo")
        try makeSkill(at: sourceC, name: "charlie")

        let engine = try SkillManagerEngine(rootDirectory: root.appendingPathComponent("manager"))
        let alpha = try engine.installLocalSkill(source: sourceA).skill
        let bravo = try engine.installLocalSkill(source: sourceB).skill
        let charlie = try engine.installLocalSkill(source: sourceC).skill
        let preset = try engine.createPreset(
            name: "Ordered",
            skillIDs: [alpha.id, bravo.id, charlie.id])

        let updated = try engine.moveSkillInPreset(
            presetID: preset.id,
            skillID: charlie.id,
            offset: -1)

        XCTAssertEqual(updated.skills.sorted { $0.order < $1.order }.map(\.skillID), [
            alpha.id,
            charlie.id,
            bravo.id
        ])
        XCTAssertEqual(engine.listAudit(limit: 5).first?.action, "preset_reorder")
    }
}
