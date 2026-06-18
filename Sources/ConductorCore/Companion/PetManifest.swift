import Foundation

/// Codex Pets 宠物包的 `pet.json` 清单。抄的是**格式**：一个宠物包 = 一个目录，含
/// `pet.json` + 一张 8×9 图集（默认 `spritesheet.webp`）。Conductor 读这个格式即可渲染
/// 任何 Codex/openpets 宠物（`~/.codex/pets/` 等），不打包别人美术（授权不清）。
public struct PetManifest: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String?
    public var description: String?
    /// 图集文件名/相对路径；缺省 `spritesheet.webp`。
    public var spritesheetPath: String?

    public init(id: String, displayName: String? = nil,
                description: String? = nil, spritesheetPath: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id 必需，但容错：缺了也不抛（用空串，调用方按 isValid 过滤）。
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? ""
        displayName = Self.clean(try? c.decodeIfPresent(String.self, forKey: .displayName))
        description = Self.clean(try? c.decodeIfPresent(String.self, forKey: .description))
        spritesheetPath = Self.clean(try? c.decodeIfPresent(String.self, forKey: .spritesheetPath))
    }

    /// 图集文件名（缺省 `spritesheet.webp`）。
    public var resolvedSpritesheet: String { spritesheetPath ?? "spritesheet.webp" }

    /// 显示名（无则回落 id）。
    public var resolvedName: String {
        if let n = displayName, !n.isEmpty { return n }
        return id
    }

    /// 有 id 才算有效（无 id 的目录跳过）。
    public var isValid: Bool { !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func clean(_ raw: String??) -> String? {
        let v = (raw ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }
}
