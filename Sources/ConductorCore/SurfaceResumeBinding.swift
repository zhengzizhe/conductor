import Foundation

public struct SurfaceResumeBinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String { paneID }
    public var paneID: String
    public var kind: String
    public var checkpoint: String?
    public var command: String
    public var cwd: String?
    public var autoResume: Bool
    public var trusted: Bool
    public var updatedAt: Date

    public init(
        paneID: String,
        kind: String = "shell",
        checkpoint: String? = nil,
        command: String,
        cwd: String? = nil,
        autoResume: Bool = false,
        trusted: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.paneID = paneID
        self.kind = kind
        self.checkpoint = Self.clean(checkpoint)
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cwd = Self.clean(cwd)
        self.autoResume = autoResume
        self.trusted = trusted
        self.updatedAt = updatedAt
    }

    public var isUsable: Bool {
        !paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var restoreCommand: String {
        guard let cwd, !cwd.isEmpty else { return command }
        return "cd \(ShellCommandQuoting.singleQuote(cwd)) && \(command)"
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

public struct SurfaceResumeBindingStore: Sendable {
    private struct Snapshot: Codable {
        var version: Int
        var bindings: [String: SurfaceResumeBinding]
    }

    private static let currentVersion = 1
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> [String: SurfaceResumeBinding] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot.bindings
        }
        return (try? JSONDecoder().decode([String: SurfaceResumeBinding].self, from: data)) ?? [:]
    }

    public func binding(for paneID: String) -> SurfaceResumeBinding? {
        load()[paneID]
    }

    public func set(_ binding: SurfaceResumeBinding) throws {
        guard binding.isUsable else { return }
        var bindings = load()
        bindings[binding.paneID] = binding
        try save(bindings)
    }

    @discardableResult
    public func clear(paneID: String) throws -> SurfaceResumeBinding? {
        var bindings = load()
        let removed = bindings.removeValue(forKey: paneID)
        try save(bindings)
        return removed
    }

    public func cleanup(keeping paneIDs: Set<String>) throws {
        try save(load().filter { paneIDs.contains($0.key) })
    }

    private func save(_ bindings: [String: SurfaceResumeBinding]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = Snapshot(version: Self.currentVersion, bindings: bindings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
    }
}
