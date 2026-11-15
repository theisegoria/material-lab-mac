import XCTest

final class MaterialCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// MARKETING_LANG=ja runs the app (and the label lookups below) in Japanese.
    private var japanese: Bool { ProcessInfo.processInfo.environment["MARKETING_LANG"] == "ja" }
    private func label(_ english: String) -> String {
        guard japanese else { return english }
        return ["Photos": "写真", "Relit": "ライティング", "Tiled": "タイル", "Compare": "比較", "Map": "マップ",
                "Normal": "ノーマル", "Height": "高さ", "Albedo": "アルベド", "Cancel": "キャンセル", "Done": "完了",
                "Tile size": "タイルの実寸"][english] ?? english
    }

    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        if japanese { app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"] }
        app.launchEnvironment["MATERIAL_CAPTURE_RESET"] = "1"
        app.launch()
        return app
    }

    /// Picks the most recent photo in the simulator library through the out-of-process PhotosUI picker.
    private func importFirstPhoto(_ app: XCUIApplication) {
        let photos = app.buttons[label("Photos")]
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

    /// Material library picker and export sheet. Runs only when SCREENSHOT_DIR is supplied.
    func testPresetAndExportShots() throws {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR to record preset and export screenshots")
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
        let material = app.buttons["material-preset"]
        XCTAssertTrue(material.waitForExistence(timeout: 10))
        material.tap()
        let brick = app.buttons["material-preset-red-brick"]
        XCTAssertTrue(brick.waitForExistence(timeout: 10))
        sleep(1)
        shot("presets-1-picker")
        brick.tap()
        sleep(1)
        shot("presets-2-recipe")
        app.buttons["recipe-done"].tap()
        let derive = app.buttons["derive-material"]
        for _ in 0..<4 where !derive.isHittable { app.swipeUp() }
        derive.tap()
        let export = app.buttons["export-material"]
        XCTAssertTrue(export.waitForExistence(timeout: 120))
        for _ in 0..<4 where !export.isHittable { app.swipeUp() }
        sleep(1)
        shot("export-1-card")
        export.tap()
        XCTAssertTrue(app.switches["export-target-glb"].waitForExistence(timeout: 10))
        app.switches["export-target-glb"].tap()
        app.switches["export-target-unreal"].tap()
        sleep(1)
        shot("export-2-sheet")
        app.buttons["export-targets-save"].tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 60), "The Files exporter should open with the export folder")
        sleep(1)
        shot("export-3-files")
    }

    /// Relit and 3D shape preview modes, and the Your maps section. Runs only when SCREENSHOT_DIR is supplied.
    func testPreviewModeShots() throws {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR to record preview mode screenshots")
        }
        func shot(_ name: String) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        let app = launchFresh()
        importFirstPhoto(app)
        XCTAssertTrue(app.textFields["semantic-label"].waitForExistence(timeout: 20))
        let modes = app.segmentedControls["preview-mode"]
        modes.buttons["Relit"].tap()
        sleep(3)
        shot("preview-relit")
        modes.buttons["3D"].tap()
        sleep(3)
        let shapeMenu = app.buttons["preview-shape"]
        XCTAssertTrue(shapeMenu.waitForExistence(timeout: 10))
        shapeMenu.tap()
        app.buttons["Cube"].tap()
        sleep(3)
        shot("preview-cube")
        app.buttons["open-recipe"].tap()
        let yourMaps = app.buttons["authored-normal"]
        var swipes = 0
        while !(yourMaps.exists && yourMaps.isHittable) && swipes < 6 { app.swipeUp(velocity: .slow); swipes += 1 }
        sleep(1)
        shot("recipe-your-maps")
    }

    /// Marketing screenshots. Runs only when MARKETING_DIR is supplied
    /// (`TEST_RUNNER_MARKETING_DIR=/path xcodebuild test -only-testing:MaterialCaptureUITests/testMarketingTour …`).
    /// Expects the hero texture as the most recent photo in the simulator library.
    func testMarketingTour() throws {
        guard let directory = ProcessInfo.processInfo.environment["MARKETING_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set MARKETING_DIR to record marketing screenshots")
        }
        let suffix = ProcessInfo.processInfo.environment["MARKETING_SUFFIX"] ?? ""
        let materialName = ProcessInfo.processInfo.environment["MARKETING_LABEL"] ?? (japanese ? "赤い耐火レンガ" : "Red fireclay brick")
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
        XCTAssertTrue(app.buttons[label("Photos")].waitForExistence(timeout: 20))
        shot("00-capture", top: false)
        importFirstPhoto(app)
        let field = app.textFields["semantic-label"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(materialName)
        app.toolbars.buttons[label("Done")].firstMatch.tap()

        // Material library: Red brick.
        app.buttons["open-recipe"].firstMatch.tap()
        let material = app.buttons["material-preset"]
        XCTAssertTrue(material.waitForExistence(timeout: 10))
        material.tap()
        let brick = app.buttons["material-preset-red-brick"]
        XCTAssertTrue(brick.waitForExistence(timeout: 10))
        shot("08-materials", settle: 2, top: false)
        brick.tap()
        shot("09-recipe", settle: 2, top: false)
        let yourMaps = app.switches["hand-made-albedo"]
        var swipes = 0
        while !(yourMaps.exists && yourMaps.isHittable) && swipes < 8 { app.swipeUp(velocity: .slow); swipes += 1 }
        app.swipeUp(velocity: .slow)
        shot("10-your-maps", settle: 1, top: false)
        // Fine tuning (1.5.0): tile size, mid-scale relief and follow colour.
        // Expand the recipe sheet to full height so the whole section fits.
        let recipeBar = app.navigationBars["Recipe"]
        if recipeBar.exists {
            recipeBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)),
                       withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        // Recipe rows are sliders labelled with their titles.
        let tileSize = app.sliders[label("Tile size")]
        swipes = 0
        while !(tileSize.exists && tileSize.isHittable) && swipes < 10 { app.swipeUp(velocity: .slow); swipes += 1 }
        // Bring the Tile size row up under the sheet's header, so the section header and all three rows show.
        if tileSize.isHittable {
            let from = tileSize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        shot("13-fine-tuning", settle: 1, top: false)
        for _ in 0..<14 { app.swipeDown(velocity: .slow) }
        app.buttons["recipe-done"].tap()
        shot("01-albedo", settle: 4)

        func chip(_ title: String) {
            let button = app.buttons[title]
            if button.waitForExistence(timeout: 3) { button.tap() }
        }
        chip(label("Normal"))
        shot("02-normal")
        chip(label("Height"))
        shot("03-height")
        chip(label("Albedo"))
        let modes = app.segmentedControls["preview-mode"]
        modes.buttons[label("Relit")].tap()
        shot("04-relit", settle: 3)
        modes.buttons["3D"].tap()
        shot("05-3d", settle: 6)
        modes.buttons[label("Tiled")].tap()
        shot("06-tiled")
        modes.buttons[label("Compare")].tap()
        shot("07-compare")
        modes.buttons[label("Map")].tap()

        // Derive at full resolution, then the export sheet.
        let derive = app.buttons["derive-material"]
        for _ in 0..<4 where !derive.isHittable { app.swipeUp() }
        derive.tap()
        let export = app.buttons["export-material"]
        XCTAssertTrue(export.waitForExistence(timeout: 180))
        for _ in 0..<4 where !export.isHittable { app.swipeUp() }
        export.tap()
        XCTAssertTrue(app.switches["export-target-glb"].waitForExistence(timeout: 10))
        shot("11-export", settle: 2, top: false)
        // Close the export sheet (its close button, else a swipe down).
        let cancel = app.buttons[label("Cancel")].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() } else { app.swipeDown(velocity: .fast) }
        if app.switches["export-target-glb"].waitForExistence(timeout: 2) { app.swipeDown(velocity: .fast) }
        // The tab bar is a floating glass bar: find its Mac tab by label, whatever element type it is.
        // Scrolling collapses the tab bar to the current tab; back at the top it shows every tab.
        toTop()
        let macTab = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Mac'")).firstMatch
        XCTAssertTrue(macTab.waitForExistence(timeout: 10))
        macTab.tap()
        shot("12-mac", top: false)
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
