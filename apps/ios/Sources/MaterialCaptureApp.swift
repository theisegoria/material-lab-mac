import SwiftUI

@main
struct MaterialCaptureApp: App {
    @State private var store = CaptureStore()

    var body: some Scene {
        WindowGroup {
            CaptureHomeView(store: store)
        }
    }
}
