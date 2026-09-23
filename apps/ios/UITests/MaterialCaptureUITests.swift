import XCTest

final class MaterialCaptureUITests: XCTestCase {
    func testPhotosImportDeriveAndOpenFilesExport() throws {
        let app = XCUIApplication()
        app.launch()
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 20), "Photos import must remain available without a simulator camera")
        photos.tap()

        // PhotosUI is an extension process, so query its own accessibility tree.
        let picker = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow.photospicker")
        let firstPhoto = picker.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 15), "The imported simulator photo should be visible")
        firstPhoto.tap()

        let label = app.textFields["semantic-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 20), "Selecting a photo should open material review")
        label.tap()
        label.typeText("integration weathered panel \(UUID().uuidString.prefix(6))")
        let returnKey = app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "return")).firstMatch
        if returnKey.exists { returnKey.tap() }
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
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Import from Photos or Files to continue without a camera."]
            .waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Photos"].exists)
        XCTAssertTrue(app.buttons["Files"].exists)
        XCTAssertFalse(app.buttons["capture-material"].exists)
    }
}
