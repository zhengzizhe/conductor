import Foundation

/// 一个宠物外观模版——「模版列表」里的一项。
///
/// v1 全是**程序化绘制**：模版只定身体形状 + 配色；表情/眨眼/嘴/状态小标仍由 `PetMood`
/// 统一驱动，保证任何模版下 agent 状态都一眼可读（守 depth-first：通知可读性不被外观牺牲）。
/// 留好扩展位：将来真 8×9 Codex Pets 图集到位时，给 `Kind` 加 `.atlas(resource:)` 分支即可，
/// 渲染层按 `SpriteAtlas` 走帧，目录/设置 UI 一行不动。
public struct PetTemplate: Identifiable, Equatable, Sendable {
    /// 身体轮廓形状。
    public enum Shape: String, Sendable, CaseIterable, Codable {
        case blob       // 圆角方团（默认）
        case round      // 正圆
        case square     // 方头（小圆角）
    }

    public let id: String
    /// 显示名的 L() 键。
    public let nameKey: String
    public let shape: Shape
    /// 身体填充色（6 位 hex，不含 #）。
    public let bodyHex: String
    /// 腮红色（6 位 hex）。
    public let cheekHex: String

    public init(id: String, nameKey: String, shape: Shape, bodyHex: String, cheekHex: String) {
        self.id = id
        self.nameKey = nameKey
        self.shape = shape
        self.bodyHex = bodyHex
        self.cheekHex = cheekHex
    }
}

/// 内置模版目录。换/加模版只动这里；设置里的「模版列表」直接渲染它。
public enum PetTemplateCatalog {
    public static let builtins: [PetTemplate] = [
        PetTemplate(id: "tuanzi",  nameKey: "团子", shape: .blob,   bodyHex: "F7F5ED", cheekHex: "F2B8C6"),
        PetTemplate(id: "doudou",  nameKey: "圆豆", shape: .round,  bodyHex: "FDF1DC", cheekHex: "F4C97D"),
        PetTemplate(id: "fangtou", nameKey: "方头", shape: .square, bodyHex: "EDF1F8", cheekHex: "A9C6F2"),
        PetTemplate(id: "mochi",   nameKey: "麻薯", shape: .blob,   bodyHex: "F0E8F8", cheekHex: "C9A8E6"),
        PetTemplate(id: "matcha",  nameKey: "抹茶", shape: .round,  bodyHex: "E8F2E4", cheekHex: "9ED0A0"),
    ]

    public static let `default` = builtins[0]

    /// 按 id 取模版，找不到回落默认（守容错：旧配置/坏 id 不崩、不空）。
    public static func template(id: String?) -> PetTemplate {
        builtins.first { $0.id == id } ?? `default`
    }
}
