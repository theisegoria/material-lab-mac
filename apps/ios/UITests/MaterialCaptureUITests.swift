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

    /// Learned-geometry progress: the quick estimate, then "Refining · pass n of N · ~s". Runs only when
    /// SCREENSHOT_DIR is supplied; expects a photo in the simulator library and the bundled model.
    func testLearnedProgressShots() throws {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR to record learned-progress screenshots")
        }
        func shot(_ name: String) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        let app = launchFresh()
        importFirstPhoto(app)
        let label = app.textFields["semantic-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        label.tap()
        label.typeText("Fireclay brick")
        app.toolbars.buttons["Done"].firstMatch.tap()
        app.buttons["open-recipe"].tap()
        let slider = app.sliders["Learned geometry"]
        XCTAssertTrue(app.buttons["recipe-done"].waitForExistence(timeout: 10))
        var swipes = 0
        while !(slider.exists && slider.isHittable) && swipes < 8 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(slider.isHittable, "The learned geometry slider should be reachable in the recipe sheet")
        slider.adjust(toNormalizedSliderPosition: 1)
        let quick = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Quick estimate")).firstMatch
        if quick.waitForExistence(timeout: 30) { shot("learned-1-quick") }
        let refining = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
                                                            "Refining", "~")).firstMatch
        XCTAssertTrue(refining.waitForExistence(timeout: 120), "The full field should report passes and time left")
        shot("learned-2-refining")
    }

    /// Marketing screenshots. Runs only when MARKETING_DIR is supplied
    /// (`TEST_RUNNER_MARKETING_DIR=/path xcodebuild test -only-testing:MaterialCaptureUITests/testMarketingTour …`).
    /// Expects the hero texture as the most recent photo in the simulator library.
    func testMarketingTour() throws {
        guard let directory = ProcessInfo.processInfo.environment["MARKETING_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set MARKETING_DIR to record marketing screenshots")
        }
        let suffix = ProcessInfo.processInfo.environment["MARKETING_SUFFIX"] ?? ""
        let label = ProcessInfo.processInfo.environment["MARKETING_LABEL"] ?? "Red fireclay brick"
        let app = launchFresh()
        func toTop() {
            let scroll = app.scrollViews.firstMatch
            for _ in 0..<3 where scroll.exists { scroll.swipeDown(velocity: .fast) }
        }
        func shot(_ name: String, settle: UInt32 = 2, top: Bool = true) {
            if top { toTop() }
            sleep(settle)
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)\(suffix).png"))
        }
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 20))
        importFirstPhoto(app)
        let field = app.textFields["semantic-label"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(label)
        app.toolbars.buttons["Done"].firstMatch.tap()

        // Material prior: stone.
        let prior = app.buttons["material-prior"]
        if prior.waitForExistence(timeout: 5) {
            if !prior.isHittable { app.scrollViews.firstMatch.swipeUp() }
            prior.tap()
            let stone = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Stone")).firstMatch
            if stone.waitForExistence(timeout: 3) { stone.tap() }
        }
        // Learned geometry at full weight: expand the sheet and scroll to the slider.
        app.buttons["open-recipe"].firstMatch.tap()
        shot("04-recipe", settle: 3, top: false)
        let learned = app.sliders.matching(NSPredicate(
            format: "identifier == 'learned-geometry' OR label CONTAINS[c] 'Learned'")).firstMatch
        for _ in 0..<8 where !(learned.exists && learned.isHittable) { app.swipeUp(velocity: .slow) }
        if learned.exists, learned.isEnabled {
            learned.adjust(toNormalizedSliderPosition: 1)
        } else {
            print("MARKETING: learned slider unavailable\n\(app.debugDescription)")
        }
        for _ in 0..<8 { app.swipeDown(velocity: .slow) }
        app.buttons["recipe-done"].tap()
        // Learned inference plus the live preview.
        shot("01-albedo", settle: 30)

        func chip(_ title: String) {
            let button = app.buttons[title]
            if button.waitForExistence(timeout: 3) { button.tap() }
        }
        chip("Normal")
        shot("02-normal")
        chip("Height")
        shot("03-height")
        chip("Albedo")
        let modes = app.segmentedControls["preview-mode"]
        modes.buttons["Lit"].tap()
        shot("05-lit", settle: 6)
        modes.buttons["Tiled"].tap()
        shot("06-tiled")
        modes.buttons["Compare"].tap()
        shot("07-compare")
        modes.buttons["Map"].tap()
        app.tabBars.buttons["Mac"].tap()
        shot("08-mac", top: false)
    }

    /// Library sheet screenshot (MARKETING_DIR). Imports the newest photo twice so the grid has two entries.
    func testLibraryShot() throws {
        guard let directory = ProcessInfo.processInfo.environment["MARKETING_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set MARKETING_DIR to record the library screenshot")
        }
        let suffix = ProcessInfo.processInfo.environment["MARKETING_SUFFIX"] ?? ""
        let app = launchFresh()
        for label in ["Red fireclay brick", "Weathered brick wall"] {
            app.tabBars.buttons["Capture"].tap()
            importFirstPhoto(app)
            let field = app.textFields["semantic-label"]
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            field.tap()
            field.typeText(label)
            app.toolbars.buttons["Done"].firstMatch.tap()
            sleep(4)
        }
        app.buttons["open-library"].tap()
        XCTAssertTrue(app.buttons["library-done"].waitForExistence(timeout: 10))
        sleep(2)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("09-library\(suffix).png"))
    }
}
