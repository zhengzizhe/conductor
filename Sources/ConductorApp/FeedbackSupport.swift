import Foundation

enum FeedbackEmailValidator {
    static func isValid(_ raw: String) -> Bool {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty,
              !email.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "-" || $0 == " " }),
              email.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil else {
            return false
        }
        return true
    }
}

struct FeedbackRequest: Codable, Equatable {
    var email: String
    var message: String
    var appVersion: String
    var releaseURL: URL
    var updateChannel: String
}

struct FeedbackEndpoint {
    var domain: String
    var path: String = "/api/feedback"

    func makeURLRequest(for feedback: FeedbackRequest) throws -> URLRequest {
        guard let baseURL = URL(string: domain.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FeedbackEndpointError.invalidDomain
        }
        let endpointURL = baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(feedback)
        return request
    }
}

enum FeedbackEndpointError: Error {
    case invalidDomain
}

struct FeedbackClient {
    static let defaultDomain = "http://zzzplus.cloud"
    static let releaseURL = URL(string: "https://github.com/zhengzizhe/conductor/releases/latest")!
    static let updateChannel = "manual-github-release"

    var endpoint: FeedbackEndpoint
    var transport: (URLRequest) async throws -> Void

    init(
        domain: String = Self.defaultDomain,
        transport: @escaping (URLRequest) async throws -> Void = { _ in }
    ) {
        self.endpoint = FeedbackEndpoint(domain: domain)
        self.transport = transport
    }

    func submit(_ feedback: FeedbackRequest) async throws {
        try await transport(endpoint.makeURLRequest(for: feedback))
    }
}

enum FeedbackMetadata {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (.some(short), .some(build)) where short != build:
            return "\(short) (\(build))"
        case let (.some(short), _):
            return short
        default:
            return "0.0.1"
        }
    }
}
