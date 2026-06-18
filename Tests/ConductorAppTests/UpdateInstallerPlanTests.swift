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
            bundleIdentifier: "com.conductor.app",
            reopenAfterInstall: true)

        XCTAssertEqual(plan.executableURL, helper)
        XCTAssertEqual(plan.arguments, [
            "--dmg", dmg.path,
            "--target-app", app.path,
            "--bundle-id", "com.conductor.app",
            "--reopen", "true",
        ])
    }

    func testLaunchArgumentsCanInstallWithoutReopeningForNextLaunch() {
        let dmg = URL(fileURLWithPath: "/Users/me/Downloads/Conductor-1.2.3-arm64.dmg")
        let app = URL(fileURLWithPath: "/Applications/Conductor.app")
        let helper = URL(fileURLWithPath: "/Applications/Conductor.app/Contents/MacOS/ConductorUpdater")
        let plan = UpdateInstallerPlan(
            dmgURL: dmg,
            currentAppURL: app,
            helperURL: helper,
            bundleIdentifier: "com.conductor.app",
            reopenAfterInstall: false)

        XCTAssertEqual(plan.arguments, [
            "--dmg", dmg.path,
            "--target-app", app.path,
            "--bundle-id", "com.conductor.app",
            "--reopen", "false",
        ])
    }

    func testCurrentAppURLResolvesExecutableBundleInsteadOfNestedContents() throws {
        let executable = URL(fileURLWithPath: "/Applications/Conductor.app/Contents/MacOS/ConductorApp")
        let appURL = try UpdateInstallerPlan.currentAppURL(executableURL: executable)

        XCTAssertEqual(appURL.path, "/Applications/Conductor.app")
        XCTAssertFalse(appURL.path.hasPrefix("//"))
    }

    func testCurrentAppURLRejectsNonBundleExecutables() {
        let executable = URL(fileURLWithPath: "/usr/local/bin/ConductorApp")

        XCTAssertThrowsError(try UpdateInstallerPlan.currentAppURL(executableURL: executable))
    }

    func testPendingUpdateStorePersistsDownloadedInstaller() {
        let suiteName = "UpdateInstallerPlanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingUpdateStore(defaults: defaults)
        let pending = PendingUpdate(
            version: "1.2.3",
            dmgPath: "/Users/me/Downloads/Conductor-1.2.3-arm64.dmg")

        store.save(pending)

        XCTAssertEqual(store.load(), pending)
        store.clear()
        XCTAssertNil(store.load())
    }
}
