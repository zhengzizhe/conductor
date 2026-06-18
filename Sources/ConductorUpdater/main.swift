import AppKit
import Foundation

enum UpdaterError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownArgument(String)
    case invalidPath(String)
    case commandFailed(String, Int32, String)
    case mountPointNotFound
    case sourceAppNotFound(URL, String)
    case appStillRunning(String)

    var description: String {
        switch self {
        case .missingValue(let name):
            return "Missing value for \(name)"
        case .unknownArgument(let value):
            return "Unknown argument \(value)"
        case .invalidPath(let value):
            return "Invalid path \(value)"
        case .commandFailed(let command, let status, let stderr):
            return "\(command) failed with status \(status): \(stderr)"
        case .mountPointNotFound:
            return "Mounted DMG did not report a mount point"
        case .sourceAppNotFound(let mountPoint, let name):
            return "Could not find \(name) in \(mountPoint.path)"
        case .appStillRunning(let bundleID):
            return "\(bundleID) is still running"
        }
    }
}

struct UpdaterArguments {
    let dmgURL: URL
    let targetAppURL: URL
    let bundleIdentifier: String
    let reopenAfterInstall: Bool

    static func parse(_ raw: [String]) throws -> UpdaterArguments {
        var dmgPath: String?
        var targetPath: String?
        var bundleID: String?
        var reopenAfterInstall = true
        var index = 0
        while index < raw.count {
            let name = raw[index]
            guard ["--dmg", "--target-app", "--bundle-id", "--reopen"].contains(name) else {
                throw UpdaterError.unknownArgument(name)
            }
            let valueIndex = index + 1
            guard raw.indices.contains(valueIndex) else {
                throw UpdaterError.missingValue(name)
            }
            switch name {
            case "--dmg": dmgPath = raw[valueIndex]
            case "--target-app": targetPath = raw[valueIndex]
            case "--bundle-id": bundleID = raw[valueIndex]
            case "--reopen": reopenAfterInstall = raw[valueIndex] != "false"
            default: break
            }
            index += 2
        }
        guard let dmgPath, !dmgPath.isEmpty else { throw UpdaterError.missingValue("--dmg") }
        guard let targetPath, !targetPath.isEmpty else { throw UpdaterError.missingValue("--target-app") }
        guard let bundleID, !bundleID.isEmpty else { throw UpdaterError.missingValue("--bundle-id") }
        return UpdaterArguments(
            dmgURL: URL(fileURLWithPath: dmgPath),
            targetAppURL: URL(fileURLWithPath: targetPath),
            bundleIdentifier: bundleID,
            reopenAfterInstall: reopenAfterInstall)
    }
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let message = String(data: err, encoding: .utf8) ?? ""
        throw UpdaterError.commandFailed(executable, process.terminationStatus, message)
    }
    return out
}

func mountDMG(_ dmgURL: URL) throws -> URL {
    let data = try run("/usr/bin/hdiutil", ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"])
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard
        let dictionary = plist as? [String: Any],
        let entities = dictionary["system-entities"] as? [[String: Any]]
    else {
        throw UpdaterError.mountPointNotFound
    }
    for entity in entities {
        if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
            return URL(fileURLWithPath: mountPoint)
        }
    }
    throw UpdaterError.mountPointNotFound
}

func sourceApp(in mountPoint: URL, matching targetName: String) throws -> URL {
    let urls = try FileManager.default.contentsOfDirectory(
        at: mountPoint,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    let apps = urls.filter { $0.pathExtension == "app" }
    if let exact = apps.first(where: { $0.lastPathComponent == targetName }) {
        return exact
    }
    if let first = apps.first {
        return first
    }
    throw UpdaterError.sourceAppNotFound(mountPoint, targetName)
}

func waitForAppToExit(bundleIdentifier: String, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
        if !running { return }
        Thread.sleep(forTimeInterval: 0.5)
    }
    throw UpdaterError.appStillRunning(bundleIdentifier)
}

func replaceApp(sourceAppURL: URL, targetAppURL: URL) throws {
    let fileManager = FileManager.default
    let parent = targetAppURL.deletingLastPathComponent()
    let backupURL = parent.appendingPathComponent(".\(targetAppURL.lastPathComponent).previous-\(UUID().uuidString)")

    if fileManager.fileExists(atPath: backupURL.path) {
        try fileManager.removeItem(at: backupURL)
    }
    if fileManager.fileExists(atPath: targetAppURL.path) {
        try fileManager.moveItem(at: targetAppURL, to: backupURL)
    }
    do {
        _ = try run("/usr/bin/ditto", [sourceAppURL.path, targetAppURL.path])
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
    } catch {
        if !fileManager.fileExists(atPath: targetAppURL.path),
           fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.moveItem(at: backupURL, to: targetAppURL)
        }
        throw error
    }
}

func install(_ arguments: UpdaterArguments) throws {
    guard FileManager.default.fileExists(atPath: arguments.dmgURL.path) else {
        throw UpdaterError.invalidPath(arguments.dmgURL.path)
    }
    let mountPoint = try mountDMG(arguments.dmgURL)
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) }

    let source = try sourceApp(in: mountPoint, matching: arguments.targetAppURL.lastPathComponent)
    try waitForAppToExit(bundleIdentifier: arguments.bundleIdentifier, timeout: 60)
    try replaceApp(sourceAppURL: source, targetAppURL: arguments.targetAppURL)
    if arguments.reopenAfterInstall {
        try run("/usr/bin/open", [arguments.targetAppURL.path])
    }
}

do {
    let arguments = try UpdaterArguments.parse(Array(CommandLine.arguments.dropFirst()))
    try install(arguments)
} catch {
    let message = "[ConductorUpdater] \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
