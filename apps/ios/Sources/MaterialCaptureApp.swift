import SwiftUI

@main
struct MaterialCaptureApp: App {
    @State private var store: CaptureStore
    /// App-level so the single-use pairing survives navigation and capture edits.
    @State private var link = MacLinkStore()

    init() {
        let directory = CapturePersistence.defaultDirectory
        if ProcessInfo.processInfo.environment["MATERIAL_CAPTURE_RESET"] == "1" {
            CapturePersistence(directory: directory).clear()
        }
        _store = State(initialValue: CaptureStore(persistenceDirectory: directory))
    }

    var body: some Scene {
        WindowGroup {
            CaptureHomeView(store: store, link: link)
                .task { await store.restore() }
        }
    }
}
