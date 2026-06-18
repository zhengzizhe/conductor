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

enum FeedbackEndpointError: LocalizedError {
    case invalidDomain
    case invalidResponse
    case requestFailed(Int)
    case businessFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDomain:
            return L("反馈接口域名无效")
        case .invalidResponse:
            return L("反馈接口响应无效")
        case .requestFailed(let statusCode):
            return L("反馈接口返回状态码 %ld", statusCode)
        case .businessFailed(let message):
            return message.isEmpty ? L("反馈接口处理失败") : message
        }
    }

    var userMessage: String {
        switch self {
        case .businessFailed(let message) where !message.isEmpty:
            return message
        default:
            return L("反馈提交失败，请稍后重试。")
        }
    }
}

extension Error {
    var feedbackUserMessage: String {
        if let feedbackError = self as? FeedbackEndpointError {
            return feedbackError.userMessage
        }
        return L("反馈提交失败，请稍后重试。")
    }
}

struct FeedbackAPIResponse: Decodable, Equatable {
    var code: Int
    var message: String
    var data: FeedbackResponseData?
}

enum FeedbackResponseData: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: FeedbackResponseData])
    case array([FeedbackResponseData])
    case null

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var values: [String: FeedbackResponseData] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(FeedbackResponseData.self, forKey: key)
            }
            self = .object(values)
            return
        }

        if var array = try? decoder.unkeyedContainer() {
            var values: [FeedbackResponseData] = []
            while !array.isAtEnd {
                values.append(try array.decode(FeedbackResponseData.self))
            }
            self = .array(values)
            return
        }

        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: value,
                debugDescription: "Unsupported feedback response data value")
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct FeedbackClient {
    static let defaultDomain = "http://zzzplus.cloud"
    static let releaseURL = URL(string: "https://github.com/zhengzizhe/conductor/releases/latest")!
    static let updateChannel = "github-release-relaunch"

    var endpoint: FeedbackEndpoint
    var transport: (URLRequest) async throws -> Void

    init(
        domain: String = Self.defaultDomain,
        transport: @escaping (URLRequest) async throws -> Void = Self.defaultTransport
    ) {
        self.endpoint = FeedbackEndpoint(domain: domain)
        self.transport = transport
    }

    func submit(_ feedback: FeedbackRequest) async throws {
        try await transport(endpoint.makeURLRequest(for: feedback))
    }

    private static func defaultTransport(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(data: data, response: response)
    }

    static func validateResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackEndpointError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FeedbackEndpointError.requestFailed(httpResponse.statusCode)
        }
        let apiResponse: FeedbackAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(FeedbackAPIResponse.self, from: data)
        } catch {
            throw FeedbackEndpointError.invalidResponse
        }
        guard apiResponse.code == 0 else {
            throw FeedbackEndpointError.businessFailed(apiResponse.message)
        }
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
