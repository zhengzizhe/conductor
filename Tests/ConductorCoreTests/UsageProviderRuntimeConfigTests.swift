import XCTest
@testable import ConductorCore

final class UsageProviderRuntimeConfigTests: XCTestCase {
    func testManualCookieHeaderUsesProviderScopedEnvAndStripsCookiePrefix() {
        let env = [
            "CONDUCTOR_USAGE_CURSOR_COOKIE": " Cookie: a=1; b=2 ",
        ]

        XCTAssertEqual(
            UsageProviderRuntimeConfig.manualCookieHeader(providerID: "cursor", env: env),
            "a=1; b=2")
    }

    func testCookieSourceManualAndOffDisableBrowserCookieReads() {
        XCTAssertFalse(UsageProviderRuntimeConfig.shouldReadBrowserCookies(
            providerID: "cursor",
            env: ["CONDUCTOR_USAGE_CURSOR_COOKIE_SOURCE": "manual"]))
        XCTAssertFalse(UsageProviderRuntimeConfig.shouldReadBrowserCookies(
            providerID: "cursor",
            env: ["CONDUCTOR_USAGE_CURSOR_COOKIE_SOURCE": " off "]))
        XCTAssertFalse(UsageProviderRuntimeConfig.shouldReadBrowserCookies(
            providerID: "cursor",
            env: ["CONDUCTOR_USAGE_CURSOR_SOURCE": "manual"]))
        XCTAssertFalse(UsageProviderRuntimeConfig.shouldReadBrowserCookies(
            providerID: "cursor",
            env: ["CONDUCTOR_USAGE_CURSOR_SOURCE": "api"]))
    }

    func testCookieSourceDefaultsToBrowserReads() {
        XCTAssertTrue(UsageProviderRuntimeConfig.shouldReadBrowserCookies(providerID: "cursor", env: [:]))
        XCTAssertTrue(UsageProviderRuntimeConfig.shouldReadBrowserCookies(
            providerID: "cursor",
            env: ["CONDUCTOR_USAGE_CURSOR_COOKIE_SOURCE": "browser"]))
        XCTAssertTrue(UsageProviderRuntimeConfig.shouldReadBrowserCookies(
            providerID: "cursor",
            env: ["CONDUCTOR_USAGE_CURSOR_COOKIE_SOURCE": "auto"]))
    }
}
