import Foundation

/// 桌面通知宠物的用户配置。落盘进 `config.yaml` 的 `companion:` 段。
/// 遵循 `AppConfig` 的容错套路：自定义 `init(from:)` 缺字段用默认，`validated()` 夹紧非法值。
public struct CompanionConfig: Codable, Equatable, Sendable {
    /// 停靠角落。
    public enum Corner: String, Codable, Sendable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// 桌宠该不该显示该通知（伙伴通知关 → 宠物不冒通知气泡）。
    public static func shouldDeliverToPet(notifyPet: Bool) -> Bool { notifyPet }

    /// 系统横幅该不该发：系统通知开 → 发；系统关但伙伴开且宠物不可见 → 回退横幅别丢通知；都关 → 静默。
    public static func shouldDeliverSystemBanner(notifySystem: Bool, notifyPet: Bool, petVisible: Bool) -> Bool {
        if notifySystem { return true }
        return notifyPet && !petVisible
    }

    /// 是否显示桌面宠物。
    public var enabled: Bool
    /// 选中的模版 id（见 `PetTemplateCatalog`）。
    public var templateID: String
    /// 昵称；nil/空 = 用模版名。
    public var name: String?
    /// 默认停靠角落（用户拖动后以窗口自存档位置为准）。
    public var corner: Corner
    /// 是否显示头顶气泡。
    public var speechBubbles: Bool
    /// 待审批时是否在气泡里内联「允许/拒绝」。
    public var inlineApproval: Bool
    /// 伙伴通知：完成等事件在宠物身上冒泡。
    public var notifyPet: Bool
    /// 系统通知：macOS 原生横幅。
    public var notifySystem: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled, templateID, name, corner, speechBubbles, inlineApproval
        case notifyPet, notifySystem
        case delivery   // 旧字段：仅解码迁移，不再写出
    }

    public init(enabled: Bool = true,
                templateID: String = PetTemplateCatalog.default.id,
                name: String? = nil,
                corner: Corner = .bottomRight,
                speechBubbles: Bool = true,
                inlineApproval: Bool = true,
                notifyPet: Bool = true,
                notifySystem: Bool = true) {
        self.enabled = enabled
        self.templateID = templateID
        self.name = name
        self.corner = corner
        self.speechBubbles = speechBubbles
        self.inlineApproval = inlineApproval
        self.notifyPet = notifyPet
        self.notifySystem = notifySystem
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompanionConfig()
        enabled = c.value(.enabled, d.enabled)
        templateID = c.value(.templateID, d.templateID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        corner = c.value(.corner, d.corner)
        speechBubbles = c.value(.speechBubbles, d.speechBubbles)
        inlineApproval = c.value(.inlineApproval, d.inlineApproval)
        // 通知开关：新字段优先；缺则从旧 `delivery`（system/pet/both）迁移；都没有用默认。
        let legacy = ((try? c.decodeIfPresent(String.self, forKey: .delivery)) ?? nil)
        notifyPet = c.value(.notifyPet, legacy.map { $0 != "system" } ?? d.notifyPet)
        notifySystem = c.value(.notifySystem, legacy.map { $0 != "pet" } ?? d.notifySystem)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(templateID, forKey: .templateID)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(corner, forKey: .corner)
        try c.encode(speechBubbles, forKey: .speechBubbles)
        try c.encode(inlineApproval, forKey: .inlineApproval)
        try c.encode(notifyPet, forKey: .notifyPet)
        try c.encode(notifySystem, forKey: .notifySystem)
    }

    /// 夹紧：templateID 去空白、空才回默认——**不**按内置目录夹（atlas/发现到的宠物 id 不在
    /// Core 的程序化目录里，夹了会把它打回第一个；未知 id 留给 App 渲染层按发现结果解析）。
    /// 昵称去空白、空则置 nil。
    public func validated() -> CompanionConfig {
        var copy = self
        let id = templateID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.templateID = id.isEmpty ? PetTemplateCatalog.default.id : id
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = (trimmed?.isEmpty == false) ? trimmed : nil
        return copy
    }

    /// 当前选中的模版（解析后）。
    public var template: PetTemplate { PetTemplateCatalog.template(id: templateID) }
}
