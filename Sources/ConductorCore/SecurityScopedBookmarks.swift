import Foundation

public struct SecurityScopedBookmarkResolution: Sendable {
    public var url: URL
    public var isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

public final class SecurityScopedResourceAccess: @unchecked Sendable {
    public let url: URL
    public let isStale: Bool
    private let started: Bool
    private var stopped = false

    fileprivate init(url: URL, isStale: Bool, started: Bool) {
        self.url = url
        self.isStale = isStale
        self.started = started
    }

    public func stop() {
        guard started, !stopped else { return }
        url.stopAccessingSecurityScopedResource()
        stopped = true
    }

    deinit {
        stop()
    }
}

public enum SecurityScopedBookmarks {
    public static func bookmarkData(for url: URL) -> Data? {
        #if os(macOS)
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        #else
        nil
        #endif
    }

    public static func resolve(_ bookmarkData: Data) throws -> SecurityScopedBookmarkResolution {
        #if os(macOS)
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        return SecurityScopedBookmarkResolution(url: url, isStale: isStale)
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    public static func startAccessing(_ bookmarkData: Data?) -> SecurityScopedResourceAccess? {
        #if os(macOS)
        guard let bookmarkData,
              let resolution = try? resolve(bookmarkData) else { return nil }
        let started = resolution.url.startAccessingSecurityScopedResource()
        return SecurityScopedResourceAccess(
            url: resolution.url,
            isStale: resolution.isStale,
            started: started)
        #else
        nil
        #endif
    }
}

public final class SecurityScopedAccessRegistry {
    private var active: [String: SecurityScopedResourceAccess] = [:]

    public init() {}

    public func activate(id: String, bookmarkData: Data?) {
        guard active[id] == nil,
              let access = SecurityScopedBookmarks.startAccessing(bookmarkData) else { return }
        active[id] = access
    }

    public func deactivate(id: String) {
        active.removeValue(forKey: id)?.stop()
    }

    public func replaceAll(_ entries: [(id: String, bookmarkData: Data?)]) {
        let nextIDs = Set(entries.map(\.id))
        for id in active.keys where !nextIDs.contains(id) {
            deactivate(id: id)
        }
        for entry in entries {
            activate(id: entry.id, bookmarkData: entry.bookmarkData)
        }
    }
}
