import XCTest

final class MaterialCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MATERIAL_CAPTURE_RESET"] = "1"
        app.launch()
        return app
    }

    /// Picks the most recent photo in the simulator library through the out-of-process PhotosUI picker.
    private func importFirstPhoto(_ app: XCUIApplication) {
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 20), "Photos import must remain available without a simulator camera")
        photos.tap()
        let picker = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow.photospicker")
        let firstPhoto = picker.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 15), "The imported simulator photo should be visible")
        firstPhoto.tap()
    }

    func testPhotosImportDeriveAndOpenFilesExport() throws {
        let app = launchFresh()
        importFirstPhoto(app)

        let label = app.textFields["semantic-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 20), "Selecting a photo should open material review")
        label.tap()
        label.typeText("integration weathered panel \(UUID().uuidString.prefix(6))")
        let returnKey = app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "next")).firstMatch
        if returnKey.exists { returnKey.tap() }
        let done = app.toolbars.buttons["Done"]
        if done.exists { done.tap() }
        app.swipeUp()
        let derive = app.buttons["derive-material"]
        XCTAssertTrue(derive.waitForExistence(timeout: 10))
        derive.tap()
        let export = app.buttons["export-material-bundle"]
        XCTAssertTrue(export.waitForExistence(timeout: 90), "Derived maps should expose bundle export")
        app.swipeUp()
        let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        preview.name = "Derived map preview"
        preview.lifetime = .keepAlways
        add(preview)
        app.swipeUp()
        let review = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        review.name = "Export and Mac link controls"
        review.lifetime = .keepAlways
        add(review)
        export.tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 25), "Files export Save control should open")
        let files = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        files.name = "Files export sheet"
        files.lifetime = .keepAlways
        add(files)
        save.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed,
                       "Saving should dismiss the Files export sheet")
    }

    func testDeniedCameraStillOffersPhotoAndFileImport() {
        let app = launchFresh()
        let hint = app.staticTexts["Import from Photos or Files to continue without a camera."]
        XCTAssertTrue(hint.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Photos"].exists)
        XCTAssertTrue(app.buttons["Files"].exists)
        XCTAssertFalse(app.buttons["capture-material"].exists)
    }

    func testEmptyMaterialTabOffersCamera() {
        let app = launchFresh()
        app.tabBars.buttons["Material"].tap()
        XCTAssertTrue(app.staticTexts["No Material Yet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Camera"].exists)
        app.buttons["Open Camera"].tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 10))
    }

    /// Visual tour for design review. Runs only when SCREENSHOT_DIR is supplied
    /// (e.g. `TEST_RUNNER_SCREENSHOT_DIR=/path xcodebuild test …`).
    func testDesignTour() throws {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR to record the design tour")
        }
        let suffix = ProcessInfo.processInfo.environment["SCREENSHOT_SUFFIX"] ?? ""
        func shot(_ name: String) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)\(suffix).png"))
        }
        let app = launchFresh()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 20))
        sleep(1)
        shot("01-capture")
        app.tabBars.buttons["Material"].tap()
        XCTAssertTrue(app.staticTexts["No Material Yet"].waitForExistence(timeout: 10))
        shot("02-empty")
        app.tabBars.buttons["Capture"].tap()
        importFirstPhoto(app)
        let label = app.textFields["semantic-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        label.tap()
        label.typeText("Fireclay brick")
        app.toolbars.buttons["Done"].firstMatch.tap()
        app.swipeDown()
        sleep(2)
        shot("03-review")
        app.buttons["open-recipe"].tap()
        sleep(2)
        shot("04-recipe")
        app.buttons["recipe-done"].tap()
        sleep(1)
        let modes = app.segmentedControls["preview-mode"]
        modes.buttons["Tiled"].tap()
        sleep(1)
        shot("05-tiled")
        modes.buttons["Lit"].tap()
        sleep(4)
        shot("06-lit")
        modes.buttons["Compare"].tap()
        sleep(1)
        shot("07-compare")
        modes.buttons["Map"].tap()
        app.buttons["adjust-crop"].tap()
        sleep(2)
        shot("08-crop")
        app.buttons["crop-done"].tap()
        sleep(1)
        let derive = app.buttons["derive-material"]
        if !derive.isHittable { app.swipeUp() }
        derive.tap()
        XCTAssertTrue(app.buttons["export-material-bundle"].waitForExistence(timeout: 90))
        app.swipeUp()
        sleep(1)
        shot("09-export")
        app.swipeDown()
        app.swipeDown()
        app.tabBars.buttons["Mac"].tap()
        sleep(1)
        shot("10-mac")
    }
}
