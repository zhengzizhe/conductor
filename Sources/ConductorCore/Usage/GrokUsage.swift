import Foundation
import SweetCookieKit

/// Grok 用量取数。忠实移植自 CodexBar `Grok` provider 的「网页计费 / 浏览器 cookie」路径
/// （`GrokWebBillingFetcher` + `GrokCookieImporter`），**不依赖 grok CLI 的 RPC 路径**。
///
/// 取数路径：从浏览器里取 grok.com 的登录 cookie（要求至少含 `sso` 或 `sso-rw`）→
/// `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`（gRPC-Web + protobuf，
/// 空 body 为 5 字节 0）→ 扫描 protobuf：取 `fixed32` 字段（path 末位 == 1，值 0...100）作为已用百分比、
/// 取 `varint` 字段里落在 unix 秒区间的当作重置时间（优先 path `[1,5,1]`，取未来最近的）。
///
/// 这是 cookie 类 provider。注意：首次读取 Chrome cookie 会弹一次「Chrome 安全存储」钥匙串授权框；
/// Safari 需要「完全磁盘访问」。无登录态 / 无授权则报错。照搬自 CodexBar，本机无登录态无法实跑验证。
public enum GrokUsageError: LocalizedError, Sendable {
    case noSession
    case unauthorized
    case emptyResponse
    case invalidResponse
    case parseFailed
    case server(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noSession: L("没有找到 Grok 登录态，请在浏览器登录 grok.com（Safari 需开启完全磁盘访问）")
        case .unauthorized: L("Grok 登录态已失效，请重新登录 grok.com")
        case .emptyResponse: L("Grok 用量接口返回空数据")
        case .invalidResponse: L("Grok 用量接口返回异常")
        case .parseFailed: L("无法解析 Grok 用量数据")
        case let .server(c): L("Grok 接口错误（%ld）", c)
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum GrokUsageFetcher {
    private static let endpoint =
        URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    private static let cookieDomains = ["grok.com"]
    /// CodexBar 要求 grok.com cookie 组里至少含一个登录态 cookie 才算有会话。
    private static let sessionCookieNames: Set<String> = ["sso", "sso-rw"]
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// 是否能从浏览器拿到 Grok 登录 cookie。注意：会触发浏览器 cookie 读取（可能弹钥匙串）。
    public static func hasSession() -> Bool {
        cookieHeader() != nil
    }

    /// 跨默认浏览器顺序取 grok.com 的 cookie，要求至少含一个已知会话 cookie（`sso`/`sso-rw`），
    /// 拼成 `name=value; ...` 的 Cookie 头。
    static func cookieHeader(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let manual = UsageProviderRuntimeConfig.manualCookieHeader(providerID: "grok", env: env) {
            return manual
        }
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "grok", env: env) else {
            return nil
        }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in Browser.defaultImportOrder {
            guard let cookies = try? client.cookies(matching: query, in: browser), !cookies.isEmpty else { continue }
            guard cookies.contains(where: { sessionCookieNames.contains($0.name) }) else { continue }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }

    public static func fetch(session: URLSession = .shared) async throws -> CodexUsageSnapshot {
        guard let header = cookieHeader() else { throw GrokUsageError.noSession }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        // 空 gRPC-Web 帧：1 字节 flags + 4 字节大端长度（均为 0）。
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("Conductor", forHTTPHeaderField: "User-Agent")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw GrokUsageError.invalidResponse }
            data = d; http = h
        } catch let e as GrokUsageError {
            throw e
        } catch {
            throw GrokUsageError.network(error.localizedDescription)
        }

        if http.statusCode == 401 || http.statusCode == 403 { throw GrokUsageError.unauthorized }
        guard http.statusCode == 200 else { throw GrokUsageError.server(http.statusCode) }

        // gRPC-Web 的 trailer 里也可能藏 grpc-status（鉴权失败常见 16 / 7）。
        try validateGRPCStatus(headerFields: http.allHeaderFields, body: data)

        let billing = try parseGRPCWebResponse(data)
        return makeSnapshot(billing)
    }

    // MARK: - 快照映射

    /// CodexBar `toUsageSnapshot()`：网页计费只产出单个 primary 窗口（已用百分比 + 重置时间）。
    /// 这里把它放进 CodexUsageSnapshot 的 session（主/最短窗）位，weekly 留空。
    private static func makeSnapshot(_ billing: WebBilling) -> CodexUsageSnapshot {
        guard let percent = billing.usedPercent else {
            // CodexBar 端 percent 为 nil 时不产出窗口；这里同样返回空快照。
            return CodexUsageSnapshot(planType: nil, session: nil, weekly: nil)
        }
        let clamped = Int(max(0, min(100, percent)).rounded())
        let now = Date()
        let resetAt = billing.resetsAt ?? now
        // CodexBar 网页计费不返回窗口时长；窗口秒数用「距重置时间」推算（无重置时为 0）。
        let windowSeconds = billing.resetsAt.map { max(0, Int($0.timeIntervalSince(now))) } ?? 0
        let window = CodexUsageSnapshot.Window(
            usedPercent: clamped,
            resetAt: resetAt,
            windowSeconds: windowSeconds)
        return CodexUsageSnapshot(planType: nil, session: window, weekly: nil)
    }

    // MARK: - gRPC-Web / protobuf 解析（照搬 GrokWebBillingFetcher）

    private struct WebBilling {
        let usedPercent: Double?
        let resetsAt: Date?
    }

    private static func parseGRPCWebResponse(_ data: Data, now: Date = Date()) throws -> WebBilling {
        var payloads = grpcWebDataFrames(from: data)
        if payloads.isEmpty, looksLikeProtobufPayload(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { throw GrokUsageError.emptyResponse }

        var scan = ProtobufScan()
        for payload in payloads {
            scan.merge(scanProtobuf(payload, depth: 0))
        }

        let parsedPercent = scan.fixed32Fields
            .filter { field in
                field.path.last == 1 && field.value.isFinite && field.value >= 0 && field.value <= 100
            }
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count ? lhs.order < rhs.order : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }

        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            let raw = field.value
            guard raw >= 1_700_000_000, raw <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(raw)))
        }
        let futureResetFields = resetFields.filter { $0.date > now }
        let reset = futureResetFields
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min() ?? futureResetFields
            .map(\.date)
            .min()

        let hasUsagePeriod = scan.varintFields.contains { field in
            field.path.starts(with: [1, 6]) ||
                (field.path == [1, 8, 1] && (field.value == 1 || field.value == 2))
        }
        let noUsageYet = parsedPercent == nil &&
            scan.fixed32Fields.isEmpty &&
            reset != nil &&
            hasUsagePeriod
        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else {
            throw GrokUsageError.parseFailed
        }
        return WebBilling(usedPercent: percent, resetsAt: reset)
    }

    private static func looksLikeProtobufPayload(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    private static func grpcWebDataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index < bytes.count {
            guard index + 5 <= bytes.count else { return [] }
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { return [] }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    private static func validateGRPCStatus(headerFields: [AnyHashable: Any], body: Data) throws {
        try validateGRPCStatusFields(grpcHeaderFields(from: headerFields))
        try validateGRPCStatusFields(grpcWebTrailerFields(from: body))
    }

    private static func validateGRPCStatusFields(_ fields: [String: String]) throws {
        guard let rawStatus = fields["grpc-status"],
              let status = Int(rawStatus),
              status != 0
        else {
            return
        }
        let message = fields["grpc-message"] ?? ""
        // CodexBar 把 gRPC status 16（UNAUTHENTICATED）/特定 7（PERMISSION_DENIED 文案）当作需重新登录。
        if isAuthenticationFailure(status: status, message: message) {
            throw GrokUsageError.unauthorized
        }
        throw GrokUsageError.server(status)
    }

    private static func isAuthenticationFailure(status: Int, message: String) -> Bool {
        if status == 16 { return true }
        guard status == 7 else { return false }
        let lower = message.lowercased()
        return lower.contains("bad-credentials") ||
            lower.contains("unauthenticated") ||
            (lower.contains("oauth2") && lower.contains("could not be validated")) ||
            (lower.contains("access token") &&
                (lower.contains("invalid") ||
                    lower.contains("expired") ||
                    lower.contains("could not be validated")))
    }

    private static func grpcHeaderFields(from headers: [AnyHashable: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in headers {
            let normalizedKey = String(describing: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedKey.hasPrefix("grpc-") else { continue }
            fields[normalizedKey] = String(describing: value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .removingPercentEncoding ?? ""
        }
        return fields
    }

    private static func grpcWebTrailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0, let text = String(data: Data(bytes[start..<end]), encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    private struct ProtobufScan {
        struct Fixed32Field {
            var path: [UInt64]
            var value: Float
            var order: Int
        }

        struct VarintField {
            var path: [UInt64]
            var value: UInt64
        }

        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []

        mutating func merge(_ other: ProtobufScan) {
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
        }
    }

    private static func scanProtobuf(_ data: Data, depth: Int) -> ProtobufScan {
        scanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func scanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int) -> (scan: ProtobufScan, order: Int)
    {
        let bytes = [UInt8](data)
        var scan = ProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            let fieldStart = index
            guard let key = readVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = readVarint(bytes, index: &index) {
                    scan.varintFields.append(ProtobufScan.VarintField(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    index = fieldStart + 1
                    continue
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = scanProtobuf(
                        Data(bytes[start..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder)
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(ProtobufScan.Fixed32Field(
                    path: fieldPath,
                    value: Float(bitPattern: bitPattern),
                    order: nextOrder))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }

        return (scan, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
