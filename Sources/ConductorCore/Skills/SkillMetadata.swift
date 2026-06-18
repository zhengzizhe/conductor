import Foundation

public struct SkillMetadata: Codable, Equatable, Sendable {
    public var name: String?
    public var description: String?
    public var version: String?
    public var author: String?

    public init(name: String? = nil,
                description: String? = nil,
                version: String? = nil,
                author: String? = nil) {
        self.name = name
        self.description = description
        self.version = version
        self.author = author
    }
}

public enum SkillMetadataParser {
    public static let skillMarkerNames = ["SKILL.md", "skill.md"]

    public static func markerFile(in directory: URL, fileManager: FileManager = .default) -> URL? {
        for name in skillMarkerNames {
            let candidate = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    public static func isValidSkillDirectory(_ directory: URL,
                                             fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return markerFile(in: directory, fileManager: fileManager) != nil
    }

    public static func parse(directory: URL,
                             fileManager: FileManager = .default) -> SkillMetadata {
        guard let marker = markerFile(in: directory, fileManager: fileManager),
              let text = try? String(contentsOf: marker, encoding: .utf8) else {
            return SkillMetadata()
        }
        return parseFrontmatter(text)
    }

    public static func inferSkillName(for directory: URL,
                                      fileManager: FileManager = .default) -> String {
        let metadata = parse(directory: directory, fileManager: fileManager)
        if let name = metadata.name,
           let sanitized = sanitizeSkillName(name) {
            return sanitized
        }
        return sanitizeSkillName(directory.lastPathComponent) ?? "unknown-skill"
    }

    public static func sanitizeSkillName(_ name: String) -> String? {
        let lastComponent = URL(fileURLWithPath: name).lastPathComponent
        guard !lastComponent.isEmpty, lastComponent != ".", lastComponent != ".." else {
            return nil
        }

        let reservedCharacters = CharacterSet(charactersIn: #"<>:"/\|?*"#)
        var cleaned = String.UnicodeScalarView()
        for scalar in lastComponent.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || reservedCharacters.contains(scalar) {
                cleaned.append("_")
            } else {
                cleaned.append(scalar)
            }
        }

        var trimmed = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.last == "." {
            trimmed.removeLast()
        }

        guard !trimmed.isEmpty else { return nil }

        let reservedBasenames: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        ]
        let basename = trimmed.split(separator: ".", maxSplits: 1).first
            .map { String($0).uppercased() } ?? ""
        return reservedBasenames.contains(basename) ? "_\(trimmed)" : trimmed
    }

    public static func parseFrontmatter(_ text: String) -> SkillMetadata {
        var lines = text.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first == "---" else {
            return SkillMetadata()
        }
        lines.removeFirst()

        var values: [String: String] = [:]
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = raw.firstIndex(of: ":") else { continue }

            let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(raw[raw.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            value = unquote(value)

            switch key {
            case "name", "description", "version", "author":
                if values[key] == nil, !value.isEmpty {
                    values[key] = value
                }
            default:
                continue
            }
        }

        return SkillMetadata(
            name: values["name"],
            description: values["description"],
            version: values["version"],
            author: values["author"])
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"") ||
            (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

