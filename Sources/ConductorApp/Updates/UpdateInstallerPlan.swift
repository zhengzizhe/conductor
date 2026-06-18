import Foundation

enum UpdateInstallerPlanError: LocalizedError {
    case appBundleNotFound
    case helperNotFound(URL)
    case bundleIdentifierMissing

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound:
            return L("当前运行的 Conductor 不是 .app 包，无法自动安装更新。")
        case .helperNotFound(let url):
            return L("更新安装器缺失：%@", url.path)
        case .bundleIdentifierMissing:
            return L("当前 App 缺少 Bundle Identifier，无法自动重启。")
        }
    }
}

struct UpdateInstallerPlan: Equatable {
    let dmgURL: URL
    let currentAppURL: URL
    let helperURL: URL
    let bundleIdentifier: String
    let reopenAfterInstall: Bool

    var executableURL: URL { helperURL }

    var arguments: [String] {
        [
            "--dmg", dmgURL.path,
            "--target-app", currentAppURL.path,
            "--bundle-id", bundleIdentifier,
            "--reopen", reopenAfterInstall ? "true" : "false",
        ]
    }

    init(
        dmgURL: URL,
        currentAppURL: URL,
        helperURL: URL,
        bundleIdentifier: String,
        reopenAfterInstall: Bool
    ) {
        self.dmgURL = dmgURL
        self.currentAppURL = currentAppURL
        self.helperURL = helperURL
        self.bundleIdentifier = bundleIdentifier
        self.reopenAfterInstall = reopenAfterInstall
    }

    static func bundled(
        dmgURL: URL,
        reopenAfterInstall: Bool,
        bundle: Bundle = .main
    ) throws -> UpdateInstallerPlan {
        let executableURL = bundle.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let appURL = try currentAppURL(executableURL: executableURL)
        let helperURL = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("ConductorUpdater")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw UpdateInstallerPlanError.helperNotFound(helperURL)
        }
        guard let bundleIdentifier = bundle.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw UpdateInstallerPlanError.bundleIdentifierMissing
        }
        return UpdateInstallerPlan(
            dmgURL: dmgURL,
            currentAppURL: appURL,
            helperURL: helperURL,
            bundleIdentifier: bundleIdentifier,
            reopenAfterInstall: reopenAfterInstall)
    }

    static func currentAppURL(executableURL: URL) throws -> URL {
        var candidate = executableURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        throw UpdateInstallerPlanError.appBundleNotFound
    }
}

struct PendingUpdate: Equatable {
    let version: String
    let dmgPath: String
}

struct PendingUpdateStore {
    private enum Key {
        static let version = "update.pending.version"
        static let dmgPath = "update.pending.dmgPath"
    }

    var defaults: UserDefaults = .standard

    func save(_ update: PendingUpdate) {
        defaults.set(update.version, forKey: Key.version)
        defaults.set(update.dmgPath, forKey: Key.dmgPath)
    }

    func load() -> PendingUpdate? {
        guard
            let version = defaults.string(forKey: Key.version),
            let dmgPath = defaults.string(forKey: Key.dmgPath),
            !version.isEmpty,
            !dmgPath.isEmpty
        else { return nil }
        return PendingUpdate(version: version, dmgPath: dmgPath)
    }

    func clear() {
        defaults.removeObject(forKey: Key.version)
        defaults.removeObject(forKey: Key.dmgPath)
    }
}
