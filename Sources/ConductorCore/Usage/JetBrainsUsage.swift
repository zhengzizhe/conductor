import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// JetBrains AI（JetBrains AI Assistant 订阅）用量取数。忠实摘自 CodexBar `JetBrains` provider，
/// 自足、不走网络、不依赖 cookie：直接读本机 JetBrains IDE 写出的本地配额文件
/// `…/<IDE><版本>/options/AIAssistantQuotaManager2.xml`，
/// 解析其中 `AIAssistantQuotaManager2` 组件的 `quotaInfo` / `nextRefill`（值是经过 HTML 转义的 JSON）。
/// 配额→已用百分比 = current / maximum * 100；下次补充时间作为「会话」窗口的重置时刻。
///
/// 凭证来源：本地文件，无环境变量。macOS 探测目录：
/// `~/Library/Application Support/JetBrains/<IDE><版本>` 与 `~/Library/Application Support/Google/<AndroidStudio…>`。
public enum JetBrainsUsageError: LocalizedError, Sendable {
    case noIDEDetected
    case quotaFileNotFound(String)
    case noQuotaInfo
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .noIDEDetected:
            L("未检测到启用 AI Assistant 的 JetBrains IDE，请先在 IDE 中启用 AI Assistant")
        case let .quotaFileNotFound(path):
            L("未找到 JetBrains AI 配额文件：%@", path)
        case .noQuotaInfo:
            L("JetBrains AI 配置中未包含配额信息")
        case let .parseError(message):
            L("解析 JetBrains AI 配额失败：%@", message)
        }
    }
}

public enum JetBrainsUsageFetcher {
    private static let quotaFileName = "AIAssistantQuotaManager2.xml"

    /// 已知 JetBrains IDE 目录前缀（与 CodexBar `JetBrainsIDEDetector` 一致）。
    private static let idePrefixes = [
        "IntelliJIdea", "PyCharm", "WebStorm", "GoLand", "CLion",
        "DataGrip", "RubyMine", "Rider", "PhpStorm", "AppCode",
        "Fleet", "AndroidStudio", "RustRover", "Aqua", "DataSpell",
    ]

    /// 是否存在可读取的 JetBrains AI 本地配额文件（用于决定是否展示该 provider）。
    public static func hasCredentials() -> Bool {
        latestQuotaFilePath() != nil
    }

    public static func fetch(
        session _: URLSession = .shared) async throws -> CodexUsageSnapshot
    {
        guard let path = latestQuotaFilePath() else { throw JetBrainsUsageError.noIDEDetected }
        guard FileManager.default.fileExists(atPath: path) else {
            throw JetBrainsUsageError.quotaFileNotFound(path)
        }

        let xmlData: Data
        do {
            xmlData = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw JetBrainsUsageError.parseError(error.localizedDescription)
        }
        return try parse(xmlData)
    }

    // MARK: - 凭证（本地文件探测）

    /// macOS 上 JetBrains 配置基目录（含 Android Studio 的 Google 目录）。
    private static func configBasePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/JetBrains",
            "\(home)/Library/Application Support/Google",
        ]
    }

    private static func quotaFilePath(forIDEBasePath ideBasePath: String) -> String {
        "\(ideBasePath)/options/\(quotaFileName)"
    }

    /// 找出存在配额文件的全部 IDE 目录，按文件修改时间取最新（与 CodexBar `detectLatestIDE` 同义）。
    static func latestQuotaFilePath() -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        for basePath in configBasePaths() {
            guard fileManager.fileExists(atPath: basePath),
                  let contents = try? fileManager.contentsOfDirectory(atPath: basePath)
            else { continue }

            for dirname in contents {
                guard matchesIDEDirectory(dirname) else { continue }
                let quotaPath = quotaFilePath(forIDEBasePath: "\(basePath)/\(dirname)")
                if fileManager.fileExists(atPath: quotaPath) {
                    candidates.append(quotaPath)
                }
            }
        }

        guard !candidates.isEmpty else { return nil }

        var latestPath: String?
        var latestDate: Date?
        for path in candidates {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date
            else { continue }
            if latestDate == nil || modDate > latestDate! {
                latestDate = modDate
                latestPath = path
            }
        }
        return latestPath ?? candidates.first
    }

    private static func matchesIDEDirectory(_ dirname: String) -> Bool {
        let lower = dirname.lowercased()
        return idePrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    // MARK: - 解析

    static func parse(_ data: Data) throws -> CodexUsageSnapshot {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data)
        } catch {
            throw JetBrainsUsageError.parseError(error.localizedDescription)
        }

        let quotaInfoRaw = try? document
            .nodes(forXPath: "//component[@name='AIAssistantQuotaManager2']/option[@name='quotaInfo']/@value")
            .first?
            .stringValue
        let nextRefillRaw = try? document
            .nodes(forXPath: "//component[@name='AIAssistantQuotaManager2']/option[@name='nextRefill']/@value")
            .first?
            .stringValue

        guard let quotaInfoRaw, !quotaInfoRaw.isEmpty else {
            throw JetBrainsUsageError.noQuotaInfo
        }

        let (usedPercent, until) = try parseQuotaInfoJSON(decodeHTMLEntities(quotaInfoRaw))

        var refillNext: Date?
        if let nextRefillRaw, !nextRefillRaw.isEmpty {
            refillNext = parseRefillNext(decodeHTMLEntities(nextRefillRaw))
        }

        // 无周期接口：把当前配额作为「会话」窗口，重置时刻取下次补充时间（缺则配额到期，再缺回退 now+30 天）；周窗口留空。
        let reset = refillNext ?? until ?? Date().addingTimeInterval(30 * 86400)
        let sessionWindow = CodexUsageSnapshot.Window(
            usedPercent: usedPercent,
            resetAt: reset,
            windowSeconds: 0)

        return CodexUsageSnapshot(planType: nil, session: sessionWindow, weekly: nil)
    }

    /// 还原 IDE 写盘时对 JSON 做的 HTML 转义。
    private static func decodeHTMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    /// 解析 quotaInfo JSON，返回（已用百分比 0…100，配额到期时间）。
    private static func parseQuotaInfoJSON(_ jsonString: String) throws -> (Int, Date?) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw JetBrainsUsageError.parseError(L("配额 JSON 格式无效"))
        }

        let used = (json["current"] as? String).flatMap { Double($0) } ?? 0
        let maximum = (json["maximum"] as? String).flatMap { Double($0) } ?? 0
        let until = (json["until"] as? String).flatMap(parseDate)

        let percent: Int
        if maximum > 0 {
            percent = Int((min(100, max(0, used / maximum * 100))).rounded())
        } else {
            percent = 0
        }
        return (percent, until)
    }

    /// 解析 nextRefill JSON 的下次补充时间。
    private static func parseRefillNext(_ jsonString: String) -> Date? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json["next"] as? String).flatMap(parseDate)
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
