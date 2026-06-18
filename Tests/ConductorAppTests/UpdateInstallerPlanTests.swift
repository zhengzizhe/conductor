@testable import ConductorApp
import XCTest

final class UpdateInstallerPlanTests: XCTestCase {
    func testLaunchArgumentsCarryDownloadedDMGAndCurrentBundle() {
        let dmg = URL(fileURLWithPath: "/Users/me/Downloads/Conductor-1.2.3-arm64.dmg")
        let app = URL(fileURLWithPath: "/Applications/Conductor.app")
        let helper = URL(fileURLWithPath: "/Applications/Conductor.app/Contents/MacOS/ConductorUpdater")
        let plan = UpdateInstallerPlan(
            dmgURL: dmg,
            currentAppURL: app,
            helperURL: helper,
            bundleIdentifier: "com.conductor.app")

        XCTAssertEqual(plan.executableURL, helper)
        XCTAssertEqual(plan.arguments, [
            "--dmg", dmg.path,
            "--target-app", app.path,
            "--bundle-id", "com.conductor.app",
        ])
    }

    func testCurrentAppURLResolvesExecutableBundleInsteadOfNestedContents() throws {
        let executable = URL(fileURLWithPath: "/Applications/Conductor.app/Contents/MacOS/ConductorApp")
        let appURL = try UpdateInstallerPlan.currentAppURL(executableURL: executable)

        XCTAssertEqual(appURL.path, "/Applications/Conductor.app")
    }

    func testCurrentAppURLRejectsNonBundleExecutables() {
        let executable = URL(fileURLWithPath: "/usr/local/bin/ConductorApp")

        XCTAssertThrowsError(try UpdateInstallerPlan.currentAppURL(executableURL: executable))
    }
}
