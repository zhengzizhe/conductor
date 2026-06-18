import XCTest
@testable import ConductorCore

final class PetTemplateTests: XCTestCase {
    func testCatalogNonEmptyAndDefaultIsFirst() {
        XCTAssertFalse(PetTemplateCatalog.builtins.isEmpty)
        XCTAssertEqual(PetTemplateCatalog.default.id, PetTemplateCatalog.builtins[0].id)
    }

    func testIDsUnique() {
        let ids = PetTemplateCatalog.builtins.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "模版 id 必须唯一")
    }

    func testHexAreSixChars() {
        for t in PetTemplateCatalog.builtins {
            XCTAssertEqual(t.bodyHex.count, 6, "\(t.id) bodyHex")
            XCTAssertEqual(t.cheekHex.count, 6, "\(t.id) cheekHex")
            XCTAssertTrue(t.bodyHex.allSatisfy(\.isHexDigit))
            XCTAssertTrue(t.cheekHex.allSatisfy(\.isHexDigit))
        }
    }

    func testLookupKnownAndFallback() {
        XCTAssertEqual(PetTemplateCatalog.template(id: "fangtou").id, "fangtou")
        XCTAssertEqual(PetTemplateCatalog.template(id: "does-not-exist").id, PetTemplateCatalog.default.id)
        XCTAssertEqual(PetTemplateCatalog.template(id: nil).id, PetTemplateCatalog.default.id)
    }
}
