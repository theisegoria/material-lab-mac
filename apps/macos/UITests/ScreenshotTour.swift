import XCTest

/// Real-window screenshots of the Mac app (Liquid Glass renders as on screen), as XCTest
/// attachments. MATERIAL_LAB_UITEST_PHOTO (pass TEST_RUNNER_MATERIAL_LAB_UITEST_PHOTO to
/// xcodebuild) is the surface photo to derive; MATERIAL_LAB_UITEST_APPEARANCE is dark or light.
final class ScreenshotTour: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var appearance: String { env["MATERIAL_LAB_UITEST_APPEARANCE"] ?? "dark" }

    override func setUp() { continueAfterFailure = false }

    private func launch(staged: Bool, welcome: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleInterfaceStyle", appearance == "dark" ? "Dark" : "Light",
                               "-materialLab.welcomeShown", welcome ? "NO" : "YES",
                               "-NSQuitAlwaysKeepsWindows", "NO", "-AppleLanguages", "(en)"]
        if staged {
            guard let photo = env["MATERIAL_LAB_UITEST_PHOTO"] else { throw XCTSkip("Set MATERIAL_LAB_UITEST_PHOTO") }
            app.launchEnvironment["MATERIAL_LAB_UITEST_SOURCE"] = photo
            app.launchEnvironment["MATERIAL_LAB_UITEST_PRESET"] = env["MATERIAL_LAB_UITEST_PRESET"] ?? "red-brick"
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String, after seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "\(name)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test1Welcome() throws {
        let app = try launch(staged: false, welcome: true)
        shoot(app, "mac-01-welcome", after: 3)
        app.terminate()
    }

    func test2Derived() throws {
        let app = try launch(staged: true)
        shoot(app, "mac-02-derived", after: 12)
        app.terminate()
    }
}
