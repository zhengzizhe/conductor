import Foundation

enum UsageProviderRuntimeConfig {
    static func manualCookieHeader(
        providerID: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        normalizedHeader(env["CONDUCTOR_USAGE_\(envSafe(providerID))_COOKIE"])
    }

    static func shouldReadBrowserCookies(
        providerID: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let cookieSource = cookieSource(providerID: providerID, env: env) {
            switch cookieSource {
            case "manual", "off":
                return false
            default:
                return true
            }
        }
        switch sourceMode(providerID: providerID, env: env) {
        case "api", "cli", "file", "keychain", "manual", "oauth", "off", "token":
            return false
        case "browser":
            return true
        default:
            return true
        }
    }

    static func shouldUseLocalCredentials(
        providerID: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch sourceMode(providerID: providerID, env: env) {
        case "manual", "off":
            return false
        default:
            return true
        }
    }

    static func cookieSource(
        providerID: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        normalized(env["CONDUCTOR_USAGE_\(envSafe(providerID))_COOKIE_SOURCE"])?.lowercased()
    }

    static func sourceMode(
        providerID: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        normalized(env["CONDUCTOR_USAGE_\(envSafe(providerID))_SOURCE"])?.lowercased()
    }

    private static func normalizedHeader(_ raw: String?) -> String? {
        guard var value = normalized(raw) else { return nil }
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func envSafe(_ raw: String) -> String {
        raw.uppercased().map { ch in
            ch.isLetter || ch.isNumber ? ch : "_"
        }.reduce(into: "") { $0.append($1) }
    }
}
