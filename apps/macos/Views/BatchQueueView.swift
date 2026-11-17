import SwiftUI

/// Per-source status of the current batch, with retry for failures and a JSON report.
struct BatchQueueView: View {
    @Bindable var store: MaterialLabStore

    var body: some View {
        VStack(spacing: 0) {
            WatchFolderBar(store: store, watch: store.watch)
            Divider()
            if store.batchItems.isEmpty {
                ContentUnavailableView("No Batch Yet", systemImage: "square.stack.3d.down.right",
                                       description: Text("Choose Material › Batch Export Eligible Sources to queue every reviewed source with the current recipe."))
            } else {
                Table(store.batchItems) {
                    TableColumn("Source") { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.origin.symbol)
                                .foregroundStyle(.secondary)
                                .help(item.origin.title)
                                .accessibilityLabel(item.origin.title)
                            Text(item.source.displayName).lineLimit(1)
                        }
                    }
                    TableColumn("Status") { item in status(item.state) }
                        .width(min: 140, ideal: 220)
                    TableColumn("Time") { item in
                        Text(item.duration.map { String(format: "%.1f s", $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(70)
                    TableColumn("") { item in
                        if let bundle = item.bundle {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([bundle])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Show the bundle in Finder")
                        }
                    }
                    .width(28)
                }
            }
            Divider()
            HStack {
                if store.isBatching {
                    ProgressView(value: Double(store.batchProgress)).frame(width: 160)
                    Text(store.status).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(store.batchDoneCount) exported · \(store.batchFailedCount) failed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isBatching {
                    Button("Cancel") { store.cancel() }
                } else {
                    Button("Retry Failed") { store.retryFailedBatchItems() }
                        .disabled(store.batchFailedCount == 0 &&
                                  !store.batchItems.contains { $0.state == .cancelled })
                    Button("Save Report…") { store.saveBatchReport() }
                        .disabled(store.batchItems.isEmpty)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 380)
    }

    @ViewBuilder
    private func status(_ state: MaterialLabStore.BatchItem.State) -> some View {
        switch state {
        case .queued: Label("Queued", systemImage: "clock").foregroundStyle(.secondary)
        case .running: Label("Deriving…", systemImage: "wand.and.sparkles").foregroundStyle(.tint)
        case .done: Label("Exported", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange).lineLimit(2).help(message)
        case .cancelled: Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}

extension MaterialLabStore.BatchItem.Origin {
    var symbol: String {
        switch self {
        case .batch: "square.stack.3d.down.right"
        case .library: "square.grid.2x2"
        case .watchFolder: "folder.badge.gearshape"
        }
    }

    var title: String {
        switch self {
        case .batch: String(localized: "Batch export")
        case .library: String(localized: "Library selection")
        case .watchFolder: String(localized: "Watch folder")
        }
    }
}

/// Watch folder status and settings: folder, recipe, formats, export folder, pause/resume.
private struct WatchFolderBar: View {
    @Bindable var store: MaterialLabStore
    let watch: WatchFolderService

    private var settings: WatchFolderSettings { store.watchSettings }

    private var statusLine: String {
        guard let folder = settings.folderURL else {
            return String(localized: "New photos added to a folder are derived with a saved recipe and exported automatically.")
        }
        switch watch.state {
        case .watching: return String(localized: "Watching \(folder.lastPathComponent) · \(store.watchRecipeTitle)")
        case .paused: return String(localized: "Paused · new photos wait until you resume")
        case .missing: return String(localized: "The folder is missing. Reconnect it or choose another.")
        case .off: return String(localized: "Not watching")
        }
    }

    private var symbol: (String, Color) {
        switch watch.state {
        case .watching: ("folder.badge.gearshape", .accentColor)
        case .paused: ("pause.circle", .orange)
        case .missing: ("exclamationmark.triangle", .orange)
        case .off: ("folder.badge.plus", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol.0)
                    .font(.title3)
                    .foregroundStyle(symbol.1)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Watch Folder").font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if settings.folderURL != nil {
                    Button {
                        store.setWatchPaused(watch.state != .paused)
                    } label: {
                        Label(watch.state == .paused ? "Resume" : "Pause",
                              systemImage: watch.state == .paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.glass)
                    .disabled(watch.state == .missing || watch.state == .off)
                    .accessibilityIdentifier("watch-folder-pause")
                    Menu {
                        Button("Change Folder…") { store.chooseWatchFolder() }
                        Button("Show in Finder") {
                            if let folder = settings.folderURL { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                        Divider()
                        Button("Stop Watching", role: .destructive) { store.stopWatching() }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                } else {
                    Button("Choose Folder…") { store.chooseWatchFolder() }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("watch-folder-choose")
                }
            }
            if settings.folderURL != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { options }
                    VStack(alignment: .leading, spacing: 8) { options }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Watch folder")
    }

    @ViewBuilder
    private var options: some View {
        Picker("Recipe", selection: Binding(get: { store.watchSettings.recipeID },
                                            set: { store.watchSettings.recipeID = $0 })) {
            Text("Default (Flat)").tag(UUID?.none)
            if !store.savedRecipes.isEmpty {
                Divider()
                ForEach(store.savedRecipes) { saved in
                    Text(saved.name).tag(Optional(saved.id))
                }
            }
        }
        .fixedSize()
        .help("The saved recipe new photos derive with (save one from the inspector's Saved recipes menu)")
        Menu {
            ForEach(ExportTarget.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(ExportTarget.all.filter { $0.group == group }) { target in
                        Toggle(target.title, isOn: Binding(get: { store.watchSettings.formats.contains(target.id) },
                                                           set: { _ in store.toggleWatchFormat(target.id) }))
                    }
                }
            }
        } label: {
            Label(settings.formats.isEmpty ? String(localized: "Bundle only")
                  : String(localized: "Bundle + \(settings.formats.count) formats"),
                  systemImage: "square.and.arrow.up")
        }
        .fixedSize()
        .help("Formats written beside each bundle")
        Button {
            store.chooseWatchOutput()
        } label: {
            Label(settings.outputURL?.lastPathComponent ?? "", systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(settings.outputURL.map { String(localized: "Exports to \($0.path)") } ?? "")
    }
}
