import Foundation
#if os(macOS)
import SQLite3
import SweetCookieKit
#endif

/// Windsurf 用量取数。忠实移植自 CodexBar `Windsurf` provider。该 provider 同时具备两条取数路径，
/// 与源码一致；按 conductor 约定「本地优先」：
///
/// 1. **本地（local）**：读 `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`
///    （SQLite，VSCode 风格 ItemTable）里 `windsurf.settings.cachedPlanInfo` 的缓存 JSON，
///    解析 `quotaUsage`（日/周剩余百分比）；无配额则回退 `usage`（messages / flow actions 额度）。
///    不发网络、不弹钥匙串。源：`WindsurfStatusProbe.swift`。
/// 2. **cookie（web）**：从 Chromium 浏览器 localStorage（windsurf.com 源）读 `devin_*` 会话材料，
///    用 protobuf 调 `windsurf.com/_backend/.../GetPlanStatus`，解析日/周剩余百分比。
///    会触发浏览器本地存储读取。源：`WindsurfWebFetcher.swift` + `WindsurfDevinSessionImporter.swift`。
///
/// 两路都有时优先「本地」；本地失败再退「cookie」。protobuf 字段号取自 CodexBar 注释
/// （Windsurf 自带 protobuf 元数据，2026-04-17 复核过线上流量）。
///
/// Windsurf 无明确「会话/周期」语义，用日配额作 session、周配额作 weekly。
/// 字段为剩余百分比 → `usedPercent = 100 - remaining`；额度类（messages/credits）→ `used/limit*100`。
/// 缺重置时间则 `reset = now + 30 天`、`weekly = nil`（仅当走额度回退路径）。
public enum WindsurfUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case noSession
    case unauthorized
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: L("未找到 Windsurf 本地用量缓存，请先安装并登录 Windsurf")
        case .noSession: L("没有找到 Windsurf 登录态，请在浏览器登录 windsurf.com")
        case .unauthorized: L("Windsurf 登录态已失效，请重新登录 windsurf.com")
        case let .server(c): L("Windsurf 接口错误（%ld）", c)
        case .invalidResponse: L("Windsurf 用量接口返回异常")
        case let .network(m): L("网络错误：%@", m)
        }
    }
}

public enum WindsurfUsageFetcher {
    #if os(macOS)
    private static let getPlanStatusURL = URL(
        string: "https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus")!
    private static let origin = "https://windsurf.com"
    private static let referer = "https://windsurf.com/profile"
    private static let storageOrigin = "https://windsurf.com"

    /// 本地缓存 DB 路径（VSCode 风格 state.vscdb）。
    private static var localDBPath: String {
        "\(NSHomeDirectory())/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
    }

    private static let localDBQuery =
        "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo' LIMIT 1;"

    /// 浏览器 localStorage 里需要凑齐的会话键。
    private static let sessionKeys = [
        "devin_session_token",
        "devin_auth1_token",
        "devin_account_id",
        "devin_primary_org_id",
    ]

    /// Chromium 系浏览器导入顺序：先 Chrome，再回退其它 Chromium 浏览器（与 CodexBar 一致）。
    private static let preferredBrowsers: [Browser] = [.chrome]
    private static let fallbackBrowsers: [Browser] = [
        .chromeBeta, .chromeCanary, .edge, .edgeBeta, .edgeCanary,
        .brave, .braveBeta, .braveNightly, .vivaldi, .arc, .arcBeta, .arcCanary,
        .dia, .chatgptAtlas, .chromium, .helium,
    ]
    #endif

    // MARK: - 凭证存在性（便宜的本地检查）

    /// 是否存在 Windsurf 本地用量缓存（state.vscdb）。本地优先路径。
    public static func hasCredentials() -> Bool {
        #if os(macOS)
        return FileManager.default.fileExists(atPath: localDBPath)
        #else
        return false
        #endif
    }

    /// 是否能从浏览器 localStorage 拿到 Windsurf 登录会话。注意：会触发浏览器本地存储读取。
    public static func hasSession(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "windsurf", env: env) else {
            return false
        }
        #if os(macOS)
        return importSession() != nil
        #else
        return false
        #endif
    }

    // MARK: - 取数

    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) async throws -> CodexUsageSnapshot {
        #if os(macOS)
        // 本地优先：有本地缓存就用本地。
        if UsageProviderRuntimeConfig.shouldUseLocalCredentials(providerID: "windsurf", env: env),
           hasCredentials()
        {
            return try readLocalSnapshot()
        }
        // 否则走 cookie/web。
        guard UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "windsurf", env: env) else {
            throw WindsurfUsageError.notLoggedIn
        }
        return try await fetchWeb(session: session)
        #else
        throw WindsurfUsageError.notLoggedIn
        #endif
    }

    #if os(macOS)
    // MARK: - 本地（SQLite 缓存）

    static func readLocalSnapshot() throws -> CodexUsageSnapshot {
        let path = localDBPath
        guard FileManager.default.fileExists(atPath: path) else { throw WindsurfUsageError.notLoggedIn }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw WindsurfUsageError.invalidResponse
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, localDBQuery, -1, &stmt, nil) == SQLITE_OK else {
            throw WindsurfUsageError.invalidResponse
        }
        defer { sqlite3_finalize(stmt) }

        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else { throw WindsurfUsageError.notLoggedIn }
        guard let jsonString = decodeSQLiteValue(stmt: stmt, index: 0),
              let jsonData = jsonString.data(using: .utf8)
        else { throw WindsurfUsageError.notLoggedIn }

        let cached: CachedPlanInfo
        do { cached = try JSONDecoder().decode(CachedPlanInfo.self, from: jsonData) }
        catch { throw WindsurfUsageError.invalidResponse }
        return cached.toSnapshot()
    }

    private static func decodeSQLiteValue(stmt: OpaquePointer?, index: Int32) -> String? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
            return decodeJSONBlob(data)
        default:
            return nil
        }
    }

    private static func decodeJSONBlob(_ data: Data) -> String? {
        // state.vscdb 把 value 声明为 BLOB；只接受仍能 parse 成 JSON 的解码，避免 UTF-16 乱码。
        for encoding in [String.Encoding.utf8, .utf16LittleEndian] {
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            let trimmed = decoded.trimmingCharacters(in: .controlCharacters)
            guard let jsonData = trimmed.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: jsonData)) != nil
            else { continue }
            return trimmed
        }
        return nil
    }

    // MARK: - cookie / web（protobuf）

    static func fetchWeb(session: URLSession) async throws -> CodexUsageSnapshot {
        guard let auth = importSession() else { throw WindsurfUsageError.noSession }

        var request = URLRequest(url: getPlanStatusURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(auth.sessionToken, forHTTPHeaderField: "x-auth-token")
        request.setValue(auth.sessionToken, forHTTPHeaderField: "x-devin-session-token")
        request.setValue(auth.auth1Token, forHTTPHeaderField: "x-devin-auth1-token")
        request.setValue(auth.accountID, forHTTPHeaderField: "x-devin-account-id")
        request.setValue(auth.primaryOrgID, forHTTPHeaderField: "x-devin-primary-org-id")
        request.httpBody = ProtoCodec.encodeRequest(authToken: auth.sessionToken, includeTopUpStatus: true)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw WindsurfUsageError.invalidResponse }
            data = d; http = h
        } catch let e as WindsurfUsageError {
            throw e
        } catch {
            throw WindsurfUsageError.network(error.localizedDescription)
        }

        if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
            throw WindsurfUsageError.unauthorized
        }
        guard http.statusCode == 200 else { throw WindsurfUsageError.server(http.statusCode) }

        let plan: PlanStatus
        do { plan = try ProtoCodec.decodeResponse(data) }
        catch { throw WindsurfUsageError.invalidResponse }
        return plan.toSnapshot()
    }

    // MARK: - 浏览器会话导入

    struct DevinSessionAuth {
        let sessionToken: String
        let auth1Token: String
        let accountID: String
        let primaryOrgID: String
    }

    /// 跨 Chromium 浏览器读取 windsurf.com 的 localStorage，凑齐 devin_* 四件套。先 Chrome，后回退。
    static func importSession() -> DevinSessionAuth? {
        if let auth = importSession(browsers: preferredBrowsers) { return auth }
        return importSession(browsers: fallbackBrowsers)
    }

    private static func importSession(browsers: [Browser]) -> DevinSessionAuth? {
        let roots = ChromiumProfileLocator.roots(
            for: browsers,
            homeDirectories: BrowserCookieClient.defaultHomeDirectories())

        for root in roots {
            for levelDBURL in profileLevelDBDirs(root: root.url) {
                let storage = readLocalStorage(from: levelDBURL)
                guard let auth = sessionAuth(from: storage) else { continue }
                return auth
            }
        }
        return nil
    }

    /// 找出某 Chromium profile root 下所有含 `Local Storage/leveldb` 的 profile 目录。
    private static func profileLevelDBDirs(root: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileDirs = entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return profileDirs.compactMap { dir in
            let levelDBURL = dir.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            return FileManager.default.fileExists(atPath: levelDBURL.path) ? levelDBURL : nil
        }
    }

    private static func readLocalStorage(from levelDBURL: URL) -> [String: String] {
        var storage: [String: String] = [:]

        let entries = ChromiumLocalStorageReader.readEntries(for: storageOrigin, in: levelDBURL)
        for entry in entries where sessionKeys.contains(entry.key) {
            storage[entry.key] = decodedStorageValue(entry.value)
        }
        if storage.count == sessionKeys.count { return storage }

        // 回退：扫全表文本项凑齐缺失键。
        let textEntries = ChromiumLocalStorageReader.readTextEntries(in: levelDBURL)
        for entry in textEntries {
            guard storage[entry.key] == nil, sessionKeys.contains(entry.key) else { continue }
            storage[entry.key] = decodedStorageValue(entry.value)
        }
        return storage
    }

    private static func decodedStorageValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data)
        {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sessionAuth(from storage: [String: String]) -> DevinSessionAuth? {
        func value(_ key: String) -> String? {
            guard let v = storage[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        guard let sessionToken = value("devin_session_token"),
              let auth1Token = value("devin_auth1_token"),
              let accountID = value("devin_account_id"),
              let primaryOrgID = value("devin_primary_org_id")
        else { return nil }
        return DevinSessionAuth(
            sessionToken: sessionToken, auth1Token: auth1Token,
            accountID: accountID, primaryOrgID: primaryOrgID)
    }

    // MARK: - 模型 + 快照转换

    /// 本地缓存 JSON（`windsurf.settings.cachedPlanInfo`）。
    private struct CachedPlanInfo: Decodable {
        let planName: String?
        let endTimestamp: Int64?
        let usage: Usage?
        let quotaUsage: QuotaUsage?

        struct Usage: Decodable {
            let messages: Int?
            let usedMessages: Int?
            let remainingMessages: Int?
            let flowActions: Int?
            let usedFlowActions: Int?
            let remainingFlowActions: Int?
        }

        struct QuotaUsage: Decodable {
            let dailyRemainingPercent: Double?
            let weeklyRemainingPercent: Double?
            let dailyResetAtUnix: Int64?
            let weeklyResetAtUnix: Int64?
        }

        func toSnapshot() -> CodexUsageSnapshot {
            var session: CodexUsageSnapshot.Window?
            var weekly: CodexUsageSnapshot.Window?

            if let quota = quotaUsage {
                if let daily = quota.dailyRemainingPercent {
                    session = makeQuotaWindow(remaining: daily, resetUnix: quota.dailyResetAtUnix)
                }
                if let week = quota.weeklyRemainingPercent {
                    weekly = makeQuotaWindow(remaining: week, resetUnix: quota.weeklyResetAtUnix)
                }
            }

            // 无配额则回退额度（messages / flow actions）。无周期 → reset = now+30天、weekly=nil。
            if session == nil, let usage {
                session = makeAmountWindow(
                    used: usage.usedMessages, remaining: usage.remainingMessages, total: usage.messages)
            }
            if weekly == nil, session != nil, quotaUsage?.weeklyRemainingPercent == nil, let usage {
                weekly = makeAmountWindow(
                    used: usage.usedFlowActions, remaining: usage.remainingFlowActions, total: usage.flowActions)
            }

            return CodexUsageSnapshot(planType: planName, session: session, weekly: weekly)
        }
    }

    /// protobuf 解出的 GetPlanStatus.PlanStatus。
    struct PlanStatus {
        var planName: String?
        var dailyQuotaRemainingPercent: Int?
        var weeklyQuotaRemainingPercent: Int?
        var dailyQuotaResetAtUnix: Int64?
        var weeklyQuotaResetAtUnix: Int64?

        func toSnapshot() -> CodexUsageSnapshot {
            let session = dailyQuotaRemainingPercent.map {
                makeQuotaWindow(remaining: Double($0), resetUnix: dailyQuotaResetAtUnix)
            }
            let weekly = weeklyQuotaRemainingPercent.map {
                makeQuotaWindow(remaining: Double($0), resetUnix: weeklyQuotaResetAtUnix)
            }
            return CodexUsageSnapshot(planType: planName, session: session, weekly: weekly)
        }
    }

    /// 配额窗：剩余百分比 → 已用百分比；缺重置则 now+1天。
    private static func makeQuotaWindow(remaining: Double, resetUnix: Int64?) -> CodexUsageSnapshot.Window {
        let used = max(0, min(100, Int((100 - remaining).rounded())))
        let reset = resetUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? Date().addingTimeInterval(86400)
        let windowSeconds = max(0, Int(reset.timeIntervalSinceNow))
        return CodexUsageSnapshot.Window(usedPercent: used, resetAt: reset, windowSeconds: windowSeconds)
    }

    /// 额度窗：used/limit*100；无周期 → reset = now+30天。
    private static func makeAmountWindow(used rawUsed: Int?, remaining rawRemaining: Int?, total rawTotal: Int?)
        -> CodexUsageSnapshot.Window?
    {
        guard let total = rawTotal, total > 0 else { return nil }
        let inferred = rawUsed ?? rawRemaining.map { max(0, total - $0) }
        guard let used = inferred else { return nil }
        let clamped = max(0, min(total, used))
        let percent = max(0, min(100, Int((Double(clamped) / Double(total) * 100).rounded())))
        let window = 30 * 24 * 3600
        return CodexUsageSnapshot.Window(
            usedPercent: percent,
            resetAt: Date().addingTimeInterval(TimeInterval(window)),
            windowSeconds: window)
    }

    // MARK: - protobuf 编解码
    //
    // 字段号取自 CodexBar：Windsurf 自带 protobuf 元数据
    // （extension.js），2026-04-17 复核线上流量。
    // 请求：1=auth_token(string), 2=include_top_up_status(varint)。
    // 响应：1=plan_status；其内 2=plan_start, 3=plan_end,
    //       14=daily_remaining%, 15=weekly_remaining%, 17=daily_reset_unix, 18=weekly_reset_unix；
    //       1=plan_info{ 2=plan_name }。

    enum ProtoError: Error { case truncated, invalidWireType }

    private enum WireType: UInt64 { case varint = 0, fixed64 = 1, lengthDelimited = 2, fixed32 = 5 }

    enum ProtoCodec {
        static func encodeRequest(authToken: String, includeTopUpStatus: Bool) -> Data {
            var data = Data()
            appendKey(1, .lengthDelimited, to: &data)
            appendString(authToken, to: &data)
            appendKey(2, .varint, to: &data)
            appendVarint(includeTopUpStatus ? 1 : 0, to: &data)
            return data
        }

        static func decodeResponse(_ data: Data) throws -> PlanStatus {
            var reader = ProtoReader(data: data)
            var plan = PlanStatus()
            while let field = try reader.nextField() {
                if field.number == 1, field.wireType == .lengthDelimited {
                    plan = try decodePlanStatus(reader.readLengthDelimitedData())
                } else {
                    try reader.skip(field.wireType)
                }
            }
            return plan
        }

        private static func decodePlanStatus(_ data: Data) throws -> PlanStatus {
            var reader = ProtoReader(data: data)
            var plan = PlanStatus()
            while let field = try reader.nextField() {
                switch (field.number, field.wireType) {
                case (1, .lengthDelimited):
                    plan.planName = try decodePlanInfoName(reader.readLengthDelimitedData())
                case (14, .varint):
                    plan.dailyQuotaRemainingPercent = try Int(reader.readVarint())
                case (15, .varint):
                    plan.weeklyQuotaRemainingPercent = try Int(reader.readVarint())
                case (17, .varint):
                    plan.dailyQuotaResetAtUnix = try Int64(reader.readVarint())
                case (18, .varint):
                    plan.weeklyQuotaResetAtUnix = try Int64(reader.readVarint())
                default:
                    try reader.skip(field.wireType)
                }
            }
            return plan
        }

        private static func decodePlanInfoName(_ data: Data) throws -> String? {
            var reader = ProtoReader(data: data)
            var name: String?
            while let field = try reader.nextField() {
                if field.number == 2, field.wireType == .lengthDelimited {
                    name = try reader.readString()
                } else {
                    try reader.skip(field.wireType)
                }
            }
            return name
        }

        private static func appendString(_ string: String, to data: inout Data) {
            let encoded = Data(string.utf8)
            appendVarint(UInt64(encoded.count), to: &data)
            data.append(encoded)
        }

        private static func appendKey(_ field: Int, _ wireType: WireType, to data: inout Data) {
            appendVarint(UInt64((field << 3) | Int(wireType.rawValue)), to: &data)
        }

        private static func appendVarint(_ value: UInt64, to data: inout Data) {
            var remaining = value
            while remaining >= 0x80 {
                data.append(UInt8((remaining & 0x7F) | 0x80))
                remaining >>= 7
            }
            data.append(UInt8(remaining))
        }
    }

    private struct ProtoField {
        let number: Int
        let wireType: WireType
    }

    private struct ProtoReader {
        private let bytes: [UInt8]
        private var index = 0

        init(data: Data) { self.bytes = Array(data) }

        mutating func nextField() throws -> ProtoField? {
            guard index < bytes.count else { return nil }
            let key = try readVarint()
            let number = Int(key >> 3)
            guard let wireType = WireType(rawValue: key & 0x07) else { throw ProtoError.invalidWireType }
            return ProtoField(number: number, wireType: wireType)
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift >= 64 { throw ProtoError.truncated }
            }
            throw ProtoError.truncated
        }

        mutating func readLengthDelimitedData() throws -> Data {
            let length = try Int(readVarint())
            guard length >= 0, index + length <= bytes.count else { throw ProtoError.truncated }
            let chunk = Data(bytes[index..<(index + length)])
            index += length
            return chunk
        }

        mutating func readString() throws -> String {
            let data = try readLengthDelimitedData()
            return String(data: data, encoding: .utf8) ?? ""
        }

        mutating func skip(_ wireType: WireType) throws {
            switch wireType {
            case .varint: _ = try readVarint()
            case .fixed64:
                guard index + 8 <= bytes.count else { throw ProtoError.truncated }
                index += 8
            case .lengthDelimited: _ = try readLengthDelimitedData()
            case .fixed32:
                guard index + 4 <= bytes.count else { throw ProtoError.truncated }
                index += 4
            }
        }
    }
    #endif
}
