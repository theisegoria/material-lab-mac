import AppKit
import SwiftUI
import TipKit

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
                    if SnapshotHarness.isActive { await SnapshotHarness.run(store: store); return }
                    try? Tips.configure([.displayFrequency(.immediate)])
                    if !WelcomeSheet.hasBeenShown { store.showWelcome = true }
                }
        }
        .defaultSize(width: 1440, height: 900)

        Window("Batch Queue", id: "batch-queue") {
            BatchQueueView(store: store)
        }
        .defaultSize(width: 720, height: 420)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Material Lab") { MaterialLabAbout.show() }
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Material Lab") { store.showWelcome = true }
            }
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
                Button("Export Material…") { store.requestExport() }
                    .keyboardShortcut("e")
                    .disabled(!store.canExport)
                Button("Save Map as PNG…") { store.exportSelectedMap() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.currentMaterial == nil)
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
        Settings {
            MaterialLabSettings(learned: store.learned)
        }
    }
}

/// Standard About panel with third-party model attribution in its credits.
enum MaterialLabAbout {
    static func show() {
        let body = NSMutableParagraphStyle()
        body.alignment = .center
        body.paragraphSpacing = 4
        func text(_ string: String, bold: Bool = false) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: bold ? NSFont.systemFont(ofSize: 11, weight: .semibold) : NSFont.systemFont(ofSize: 11),
                .foregroundColor: bold ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: body
            ])
        }
        let credits = NSMutableAttributedString()
        credits.append(text("Learned geometry\n", bold: true))
        credits.append(text("MoGe-2 (ViT-S normal) \u{00A9} Microsoft Corporation, MIT License.\n"))
        credits.append(text("DINOv2 \u{00A9} Meta Platforms, Inc., Apache License 2.0.\n"))
        credits.append(text("Runs locally through Core ML; maps are editable estimates."))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
