import AppKit
import SwiftUI

final class MaterialLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MaterialLabApp: App {
    @NSApplicationDelegateAdaptor(MaterialLabAppDelegate.self) private var delegate
    @State private var store = MaterialLabStore()

    var body: some Scene {
        Window("Material Lab", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1080, minHeight: 700)
                .task {
                    store.bootstrap()
                    if SnapshotHarness.isActive { await SnapshotHarness.run(store: store) }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Images…") { store.showSourceImporter = true }
                    .keyboardShortcut("o")
                Button("Import Capture…") { store.showBundleImporter = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Import Catalog…") { store.showCatalogImporter = true }
                    .keyboardShortcut("o", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .importExport) {
                // Same predicate as the toolbar; when blocked the action explains why.
                Button("Export Material Bundle…") { store.exportSelected() }
                    .keyboardShortcut("e")
                    .disabled(!store.canExport)
            }
            CommandMenu("Material") {
                Button("Derive Maps") { store.deriveSelected() }
                    .keyboardShortcut("r")
                    .disabled(!store.canDerive)
                Toggle("Live Update", isOn: $store.autoDerive)
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Edit Labels…") {
                    if let source = store.selectedSource { store.editMetadata(for: source) }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(store.selectedSource == nil)
                Button("Reset Recipe to Preset") { store.resetRecipe() }
                    .disabled(store.selectedSource == nil)
                Divider()
                Button("Batch Export Eligible Sources…") { store.batchDeriveVisible() }
                    .disabled(store.isBatching || store.eligibleBatchSources.isEmpty)
                if store.isDeriving || store.isBatching {
                    Button("Cancel") { store.cancel() }
                        .keyboardShortcut(".")
                }
            }
            CommandGroup(before: .sidebar) {
                Section {
                    ForEach(Array(MaterialMapKind.allCases.prefix(9).enumerated()), id: \.offset) { index, kind in
                        let maps = store.availableMaps.isEmpty ? MaterialMapKind.allCases : store.availableMaps
                        let title = maps.indices.contains(index) ? maps[index].title : kind.title
                        Button("Show \(title)") { store.selectMap(atShortcutIndex: index) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                            .disabled(!maps.indices.contains(index))
                    }
                }
                Section {
                    ForEach(Array(CanvasMode.allCases.enumerated()), id: \.offset) { index, mode in
                        Button("\(mode.title) View") { store.canvasMode = mode }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                    }
                    Button(store.canvasMode == .compare ? "Hide Before/After" : "Show Before/After (Space)") {
                        store.toggleCompare()
                    }
                }
                Divider()
            }
            InspectorCommands()
        }
    }
}
