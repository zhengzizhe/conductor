@testable import ConductorApp
import XCTest

final class FeedbackSupportTests: XCTestCase {
    func testEmailValidationAcceptsOrdinaryEmail() {
        XCTAssertTrue(FeedbackEmailValidator.isValid("user@example.com"))
        XCTAssertTrue(FeedbackEmailValidator.isValid(" user.name+tag@example.co.uk "))
    }

    func testEmailValidationRejectsInvalidEmailAndPhoneNumbers() {
        XCTAssertFalse(FeedbackEmailValidator.isValid(""))
        XCTAssertFalse(FeedbackEmailValidator.isValid("user@example"))
        XCTAssertFalse(FeedbackEmailValidator.isValid("user@@example.com"))
        XCTAssertFalse(FeedbackEmailValidator.isValid("+8613800138000"))
        XCTAssertFalse(FeedbackEmailValidator.isValid("13800138000"))
    }

    func testRequestPayloadIncludesReleaseAndUpdateMetadata() throws {
        let endpoint = FeedbackEndpoint(domain: "http://zzzplus.cloud")
        let request = FeedbackRequest(
            email: "user@example.com",
            message: "The app feedback form should keep GitHub Issue separate.",
            appVersion: "1.2.3",
            releaseURL: URL(string: "https://github.com/zhengzizhe/conductor/releases/latest")!,
            updateChannel: "manual-github-release"
        )

        let urlRequest = try endpoint.makeURLRequest(for: request)
        let body = try XCTUnwrap(urlRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(urlRequest.url?.absoluteString, "http://zzzplus.cloud/api/feedback")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(json["email"], "user@example.com")
        XCTAssertEqual(json["message"], "The app feedback form should keep GitHub Issue separate.")
        XCTAssertEqual(json["appVersion"], "1.2.3")
        XCTAssertEqual(json["releaseURL"], "https://github.com/zhengzizhe/conductor/releases/latest")
        XCTAssertEqual(json["updateChannel"], "manual-github-release")
    }
}
