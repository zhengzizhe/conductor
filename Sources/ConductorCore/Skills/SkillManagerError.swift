import Foundation

public enum SkillManagerError: LocalizedError, Sendable {
    case invalidSkillDirectory(String)
    case invalidSkillName(String)
    case missingSkill(String)
    case missingPreset(String)
    case missingProject(String)
    case missingTool(String)
    case destinationInsideSource(source: String, destination: String)
    case targetConflict(String)
    case unsupportedArchive(String)
    case ambiguousArchive(String)
    case archiveFailed(String)
    case gitFailed(String)
    case networkFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSkillDirectory(let path):
            return "Not a valid skill directory: \(path)"
        case .invalidSkillName(let name):
            return "Invalid skill name: \(name)"
        case .missingSkill(let id):
            return "Skill not found: \(id)"
        case .missingPreset(let id):
            return "Preset not found: \(id)"
        case .missingProject(let id):
            return "Project not found: \(id)"
        case .missingTool(let key):
            return "Tool not found: \(key)"
        case let .destinationInsideSource(source, destination):
            return "Destination \(destination) is inside source \(source)."
        case .targetConflict(let path):
            return "Refusing to replace unmanaged target: \(path)"
        case .unsupportedArchive(let path):
            return "Unsupported archive format: \(path)"
        case .ambiguousArchive(let path):
            return "Archive contains multiple skill directories: \(path)"
        case .archiveFailed(let message):
            return message
        case .gitFailed(let message):
            return message
        case .networkFailed(let message):
            return message
        }
    }
}
