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
            updateChannel: "github-release-relaunch"
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
        XCTAssertEqual(json["updateChannel"], "github-release-relaunch")
    }

    func testResponseProtocolRequiresBusinessSuccessCode() throws {
        let url = URL(string: "http://zzzplus.cloud/api/feedback")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let success = Data(#"{"code":0,"message":"ok","data":{"id":"feedback-1"}}"#.utf8)
        XCTAssertNoThrow(try FeedbackClient.validateResponse(data: success, response: response))

        let failure = Data(#"{"code":1001,"message":"invalid email","data":null}"#.utf8)
        XCTAssertThrowsError(try FeedbackClient.validateResponse(data: failure, response: response)) { error in
            XCTAssertEqual(error.localizedDescription, "invalid email")
            XCTAssertEqual(error.feedbackUserMessage, "invalid email")
        }
    }

    func testTransportFailureUsesUserFriendlyMessage() throws {
        let error = FeedbackEndpointError.requestFailed(502)
        XCTAssertEqual(error.localizedDescription, "反馈接口返回状态码 502")
        XCTAssertEqual(error.feedbackUserMessage, "反馈提交失败，请稍后重试。")
    }
}
