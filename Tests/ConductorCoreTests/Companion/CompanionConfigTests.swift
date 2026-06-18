import XCTest
@testable import ConductorCore

final class CompanionConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> CompanionConfig {
        try JSONDecoder().decode(CompanionConfig.self, from: Data(json.utf8))
    }

    func testDefaults() {
        let d = CompanionConfig()
        XCTAssertTrue(d.enabled)
        XCTAssertEqual(d.templateID, PetTemplateCatalog.default.id)
        XCTAssertNil(d.name)
        XCTAssertEqual(d.corner, .bottomRight)
        XCTAssertTrue(d.speechBubbles)
        XCTAssertTrue(d.inlineApproval)
    }

    func testDecodeEmptyObjectUsesDefaults() throws {
        let c = try decode("{}")
        XCTAssertEqual(c, CompanionConfig())
    }

    func testDecodePartialKeepsOthersDefault() throws {
        let c = try decode(#"{"enabled": false, "templateID": "fangtou"}"#)
        XCTAssertFalse(c.enabled)
        XCTAssertEqual(c.templateID, "fangtou")
        XCTAssertEqual(c.corner, .bottomRight)        // 缺字段回默认
    }

    func testDecodeInvalidCornerFallsBack() throws {
        let c = try decode(#"{"corner": "middle"}"#)
        XCTAssertEqual(c.corner, .bottomRight)        // 非法枚举值不崩、回默认
    }

    func testValidatedPreservesUnknownTemplateIDAndTrimsName() {
        // 未知 id（如发现到的 atlas 宠物）必须保留——否则一选就被夹回第一个。
        var c = CompanionConfig(templateID: "conductor-pixel", name: "  ")
        c = c.validated()
        XCTAssertEqual(c.templateID, "conductor-pixel")
        XCTAssertNil(c.name)

        // 空 id 才回默认。
        var blank = CompanionConfig(templateID: "   ")
        blank = blank.validated()
        XCTAssertEqual(blank.templateID, PetTemplateCatalog.default.id)

        var named = CompanionConfig(name: "  小豆  ")
        named = named.validated()
        XCTAssertEqual(named.name, "小豆")
    }

    func testTemplateAccessorResolves() {
        XCTAssertEqual(CompanionConfig(templateID: "matcha").template.id, "matcha")
        XCTAssertEqual(CompanionConfig(templateID: "bogus").template.id, PetTemplateCatalog.default.id)
    }

    func testNotifyDefaultsAndLegacyMigration() throws {
        XCTAssertTrue(CompanionConfig().notifyPet)
        XCTAssertTrue(CompanionConfig().notifySystem)
        // 新字段
        XCTAssertFalse(try decode(#"{"notifyPet":false}"#).notifyPet)
        XCTAssertTrue(try decode(#"{"notifyPet":false}"#).notifySystem)
        // 旧 delivery 迁移：system → 只系统；pet → 只伙伴；both → 都开。
        let sys = try decode(#"{"delivery":"system"}"#)
        XCTAssertFalse(sys.notifyPet); XCTAssertTrue(sys.notifySystem)
        let pet = try decode(#"{"delivery":"pet"}"#)
        XCTAssertTrue(pet.notifyPet); XCTAssertFalse(pet.notifySystem)
        let both = try decode(#"{"delivery":"both"}"#)
        XCTAssertTrue(both.notifyPet); XCTAssertTrue(both.notifySystem)
        // 新字段优先于旧字段
        let mix = try decode(#"{"delivery":"system","notifyPet":true}"#)
        XCTAssertTrue(mix.notifyPet)
    }

    func testSystemBannerGating() {
        // 系统通知开：总发横幅。
        XCTAssertTrue(CompanionConfig.shouldDeliverSystemBanner(notifySystem: true, notifyPet: true, petVisible: true))
        XCTAssertTrue(CompanionConfig.shouldDeliverSystemBanner(notifySystem: true, notifyPet: false, petVisible: true))
        // 系统关 + 伙伴开 + 宠物可见：不发横幅（交给宠物）。
        XCTAssertFalse(CompanionConfig.shouldDeliverSystemBanner(notifySystem: false, notifyPet: true, petVisible: true))
        // 系统关 + 伙伴开 + 宠物隐藏：回退横幅，别丢通知。
        XCTAssertTrue(CompanionConfig.shouldDeliverSystemBanner(notifySystem: false, notifyPet: true, petVisible: false))
        // 都关：静默。
        XCTAssertFalse(CompanionConfig.shouldDeliverSystemBanner(notifySystem: false, notifyPet: false, petVisible: false))
    }

    func testPetGating() {
        XCTAssertFalse(CompanionConfig.shouldDeliverToPet(notifyPet: false))
        XCTAssertTrue(CompanionConfig.shouldDeliverToPet(notifyPet: true))
    }

    func testRoundTripEncodeDecode() throws {
        let original = CompanionConfig(enabled: false, templateID: "mochi", name: "团子",
                                       corner: .topLeft, speechBubbles: false, inlineApproval: false)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(CompanionConfig.self, from: data)
        XCTAssertEqual(original, back)
    }
}
