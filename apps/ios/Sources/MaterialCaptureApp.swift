import SwiftUI

@main
struct MaterialCaptureApp: App {
    @State private var store: CaptureStore
    /// App-level so the single-use pairing survives navigation and capture edits.
    @State private var link = MacLinkStore()

    init() {
        let root = CaptureLibrary.defaultRoot
        if ProcessInfo.processInfo.environment["MATERIAL_CAPTURE_RESET"] == "1" {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: CaptureLibrary.legacyDirectory)
            // UI tests and the marketing tour start clean and without first-run tips.
            for key in FirstRunTip.allKeys { UserDefaults.standard.set(true, forKey: key) }
        }
        CaptureLibrary(root: root).migrateLegacy()
        _store = State(initialValue: CaptureStore(libraryDirectory: root))
    }

    var body: some Scene {
        WindowGroup {
            CaptureHomeView(store: store, link: link)
                .task { await store.restore() }
        }
    }
}
