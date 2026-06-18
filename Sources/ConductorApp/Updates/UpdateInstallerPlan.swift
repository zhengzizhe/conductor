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

    var executableURL: URL { helperURL }

    var arguments: [String] {
        [
            "--dmg", dmgURL.path,
            "--target-app", currentAppURL.path,
            "--bundle-id", bundleIdentifier,
        ]
    }

    init(dmgURL: URL, currentAppURL: URL, helperURL: URL, bundleIdentifier: String) {
        self.dmgURL = dmgURL
        self.currentAppURL = currentAppURL
        self.helperURL = helperURL
        self.bundleIdentifier = bundleIdentifier
    }

    static func bundled(dmgURL: URL, bundle: Bundle = .main) throws -> UpdateInstallerPlan {
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
            bundleIdentifier: bundleIdentifier)
    }

    static func currentAppURL(executableURL: URL) throws -> URL {
        let standardized = executableURL.standardizedFileURL
        let components = standardized.pathComponents
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else {
            throw UpdateInstallerPlanError.appBundleNotFound
        }
        let appPath = components[0...appIndex].joined(separator: "/")
        return URL(fileURLWithPath: appPath.isEmpty ? "/" : appPath)
    }
}
