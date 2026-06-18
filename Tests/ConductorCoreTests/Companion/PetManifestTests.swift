import XCTest
@testable import ConductorCore

final class PetManifestTests: XCTestCase {
    private func decode(_ json: String) throws -> PetManifest {
        try JSONDecoder().decode(PetManifest.self, from: Data(json.utf8))
    }

    func testFullManifest() throws {
        let m = try decode(#"""
        {"id":"starcorn","displayName":"Starcorn","description":"a unicorn","spritesheetPath":"sheet.webp"}
        """#)
        XCTAssertEqual(m.id, "starcorn")
        XCTAssertEqual(m.resolvedName, "Starcorn")
        XCTAssertEqual(m.resolvedSpritesheet, "sheet.webp")
        XCTAssertTrue(m.isValid)
    }

    func testDefaultsWhenMinimal() throws {
        let m = try decode(#"{"id":"blob"}"#)
        XCTAssertEqual(m.resolvedSpritesheet, "spritesheet.webp")   // 缺省图集名
        XCTAssertEqual(m.resolvedName, "blob")                       // 无名回落 id
        XCTAssertTrue(m.isValid)
    }

    func testMissingIDIsInvalidNotThrow() throws {
        let m = try decode(#"{"displayName":"无 id"}"#)
        XCTAssertFalse(m.isValid)                                    // 无 id → 跳过，不崩
    }

    func testUnknownFieldsIgnored() throws {
        let m = try decode(#"{"id":"x","author":"someone","frameRate":12}"#)
        XCTAssertEqual(m.id, "x")                                    // 未知字段不影响解码
    }

    func testBlankStringsTrimmedToDefaults() throws {
        let m = try decode(#"{"id":"x","displayName":"  ","spritesheetPath":""}"#)
        XCTAssertEqual(m.resolvedName, "x")
        XCTAssertEqual(m.resolvedSpritesheet, "spritesheet.webp")
    }
}
