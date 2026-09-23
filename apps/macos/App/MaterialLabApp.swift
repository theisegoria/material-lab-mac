import AppKit
import SwiftUI

final class MaterialLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MaterialLabApp: App {
    @NSApplicationDelegateAdaptor(MaterialLabAppDelegate.self) private var delegate
    @State private var store = MaterialLabStore()

    var body: some Scene {
        Window("Material Lab", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1120, minHeight: 700)
                .task { store.bootstrap() }
        }
        .defaultSize(width: 1380, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Source…") { store.showSourceImporter = true }
                    .keyboardShortcut("o")
                Button("Import Material Bundle…") { store.showBundleImporter = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Export Derived Maps…") { store.exportSelected() }
                    .keyboardShortcut("e")
                    .disabled(store.derived == nil)
            }
        }
    }
}
