import CryptoKit
import Foundation

enum SkillFileUtilities {
    static let ignoredContentNames: Set<String> = [".git", ".DS_Store", "Thumbs.db", ".gitignore"]
    static let recursiveScanSkipNames: Set<String> = [".hub", ".git", "node_modules"]

    static func hashDirectory(_ directory: URL, fileManager: FileManager = .default) throws -> String {
        var hasher = SHA256()
        for entry in try contentFiles(in: directory, fileManager: fileManager) {
            hasher.update(data: Data(entry.relativePath.utf8))
            hasher.update(data: try Data(contentsOf: entry.url))
            #if os(macOS)
            if let executableBits = try? executableBits(of: entry.url) {
                var bits = executableBits.littleEndian
                hasher.update(data: Data(bytes: &bits, count: MemoryLayout<UInt16>.size))
            }
            #endif
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func copySkillDirectory(from source: URL,
                                   to destination: URL,
                                   fileManager: FileManager = .default) throws {
        try ensureDestinationNotInsideSource(source: source, destination: destination, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try removeTarget(at: destination, fileManager: fileManager)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants])

        for entry in entries {
            let name = entry.lastPathComponent
            if name == ".git" || name == ".DS_Store" { continue }

            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }

            let target = destination.appendingPathComponent(name)
            if values.isDirectory == true {
                try copySkillDirectory(from: entry, to: target, fileManager: fileManager)
            } else {
                try fileManager.copyItem(at: entry, to: target)
            }
        }
    }

    static func ensureDestinationNotInsideSource(source: URL,
                                                destination: URL,
                                                fileManager: FileManager = .default) throws {
        let sourceCanonical = canonicalPath(for: source, fileManager: fileManager)
        let destinationCanonical = canonicalPathForPotentialDestination(
            destination,
            fileManager: fileManager)

        if destinationCanonical == sourceCanonical ||
            destinationCanonical.hasPrefix(sourceCanonical + "/") {
            throw SkillManagerError.destinationInsideSource(
                source: source.path,
                destination: destination.path)
        }
    }

    static func syncSkill(source: URL,
                          target: URL,
                          mode: SkillTargetRecord.Mode,
                          existingRecord: SkillTargetRecord?,
                          currentHash: String?,
                          fileManager: FileManager = .default) throws -> SkillTargetRecord.Mode {
        if isTargetCurrent(source: source,
                           target: target,
                           mode: mode,
                           existingRecord: existingRecord,
                           currentHash: currentHash,
                           fileManager: fileManager) {
            return mode
        }

        try ensureDestinationNotInsideSource(source: source, destination: target, fileManager: fileManager)
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: target.path) {
            let mayReplace = existingRecord != nil || symlink(at: target, pointsTo: source, fileManager: fileManager)
            guard mayReplace else {
                throw SkillManagerError.targetConflict(target.path)
            }
            try removeTarget(at: target, fileManager: fileManager)
        }

        switch mode {
        case .symlink:
            do {
                try fileManager.createSymbolicLink(at: target, withDestinationURL: source)
                return .symlink
            } catch {
                try copySkillDirectory(from: source, to: target, fileManager: fileManager)
                return .copy
            }
        case .copy:
            try copySkillDirectory(from: source, to: target, fileManager: fileManager)
            return .copy
        }
    }

    static func removeTarget(at target: URL, fileManager: FileManager = .default) throws {
        guard let metadata = try? fileManager.attributesOfItem(atPath: target.path) else {
            return
        }
        if metadata[.type] as? FileAttributeType == .typeSymbolicLink {
            try fileManager.removeItem(at: target)
        } else {
            try fileManager.removeItem(at: target)
        }
    }

    static func symlink(at target: URL,
                        pointsTo source: URL,
                        fileManager: FileManager = .default) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: target.path) else {
            return false
        }
        let resolved: URL
        if destination.hasPrefix("/") {
            resolved = URL(fileURLWithPath: destination)
        } else {
            resolved = target.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return canonicalPath(for: resolved, fileManager: fileManager) ==
            canonicalPath(for: source, fileManager: fileManager)
    }

    static func collectSkillDirectories(in directory: URL,
                                        recursive: Bool,
                                        centralDirectory: URL,
                                        fileManager: FileManager = .default) -> [URL] {
        if recursive {
            var visited = Set<String>()
            var results: [URL] = []
            collectSkillDirectoriesRecursive(
                in: directory,
                centralDirectory: centralDirectory,
                visited: &visited,
                results: &results,
                fileManager: fileManager)
            return results
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        return entries.filter { entry in
            guard isDirectoryOrSymlink(entry, fileManager: fileManager),
                  !symlinkPointsInsideCentral(entry, centralDirectory: centralDirectory, fileManager: fileManager) else {
                return false
            }
            return SkillMetadataParser.isValidSkillDirectory(entry, fileManager: fileManager)
        }
    }

    static func contentFileMap(in directory: URL,
                               fileManager: FileManager = .default) throws -> [String: URL] {
        Dictionary(uniqueKeysWithValues: try contentFiles(in: directory, fileManager: fileManager)
            .map { ($0.relativePath, $0.url) })
    }

    private static func collectSkillDirectoriesRecursive(in directory: URL,
                                                         centralDirectory: URL,
                                                         visited: inout Set<String>,
                                                         results: inout [URL],
                                                         fileManager: FileManager) {
        let canonical = canonicalPath(for: directory, fileManager: fileManager)
        guard visited.insert(canonical).inserted else { return }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            return
        }

        for entry in entries {
            guard isDirectoryOrSymlink(entry, fileManager: fileManager) else { continue }
            if recursiveScanSkipNames.contains(entry.lastPathComponent) { continue }
            if symlinkPointsInsideCentral(entry, centralDirectory: centralDirectory, fileManager: fileManager) {
                continue
            }
            if SkillMetadataParser.isValidSkillDirectory(entry, fileManager: fileManager) {
                results.append(entry)
                continue
            }
            collectSkillDirectoriesRecursive(
                in: entry,
                centralDirectory: centralDirectory,
                visited: &visited,
                results: &results,
                fileManager: fileManager)
        }
    }

    private static func contentFiles(in directory: URL,
                                     fileManager: FileManager) throws -> [(relativePath: String, url: URL)] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []) else {
            return []
        }

        var files: [(relativePath: String, url: URL)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if ignoredContentNames.contains(name) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append((relativePath(from: directory, to: url), url))
        }
        files.sort { $0.relativePath < $1.relativePath }
        return files
    }

    private static func isTargetCurrent(source: URL,
                                        target: URL,
                                        mode: SkillTargetRecord.Mode,
                                        existingRecord: SkillTargetRecord?,
                                        currentHash: String?,
                                        fileManager: FileManager) -> Bool {
        switch mode {
        case .symlink:
            return symlink(at: target, pointsTo: source, fileManager: fileManager)
        case .copy:
            guard let existingRecord,
                  let stored = existingRecord.sourceHash,
                  let currentHash,
                  stored == currentHash else {
                return false
            }
            return fileManager.fileExists(atPath: target.path)
        }
    }

    private static func symlinkPointsInsideCentral(_ url: URL,
                                                   centralDirectory: URL,
                                                   fileManager: FileManager) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let resolved = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appendingPathComponent(destination)
        let target = canonicalPath(for: resolved, fileManager: fileManager)
        let central = canonicalPath(for: centralDirectory, fileManager: fileManager)
        return target == central || target.hasPrefix(central + "/")
    }

    private static func isDirectoryOrSymlink(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func canonicalPath(for url: URL, fileManager: FileManager) -> String {
        _ = fileManager
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func canonicalPathForPotentialDestination(_ url: URL,
                                                             fileManager: FileManager) -> String {
        if fileManager.fileExists(atPath: url.path) {
            return canonicalPath(for: url, fileManager: fileManager)
        }
        let parent = url.deletingLastPathComponent()
        let resolvedParent = canonicalPath(for: parent, fileManager: fileManager)
        return URL(fileURLWithPath: resolvedParent)
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
            .path
    }

    private static func relativePath(from root: URL, to file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath == rootPath { return "" }
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return file.lastPathComponent
    }

    #if os(macOS)
    private static func executableBits(of url: URL) throws -> UInt16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attrs[.posixPermissions] as? NSNumber else { return 0 }
        return UInt16(number.uint16Value & 0o111)
    }
    #endif
}
