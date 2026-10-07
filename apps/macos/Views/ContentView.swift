import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: MaterialLabStore
    @State private var dropTargeted = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            SourceSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dropDestination(for: URL.self) { items, _ in
            store.handleDrop(items)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { dropTargeted = targeted }
        }
        .overlay {
            if dropTargeted { DropOverlay().transition(.opacity) }
        }
        .onOpenURL { url in store.handleDrop([url]) }
        .onAppear { store.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in store.undoManager = manager }
        .fileImporter(
            isPresented: $store.showSourceImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): store.importSources(urls)
            case .failure(let error): store.alert = MaterialAlert(message: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $store.showCatalogImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): store.importCatalog(url)
            case .failure(let error): store.alert = MaterialAlert(message: error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $store.showBundleImporter,
            allowedContentTypes: [UTType(filenameExtension: "pbrcapture") ?? .json, .json]
        ) { result in
            switch result {
            case .success(let url): store.importCapture(url)
            case .failure(let error): store.alert = MaterialAlert(message: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $store.showReliefImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { store.recipe.reliefMaskURL = url }
        }
        .fileImporter(isPresented: Binding(get: { store.authoredImporter != nil },
                                           set: { if !$0 { store.authoredImporter = nil } }),
                      allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let slot = store.authoredImporter { slot.set(url, in: &store.recipe) }
            store.authoredImporter = nil
        }
        .fileImporter(isPresented: $store.showHeightImporter, allowedContentTypes: [.png, .tiff, .image]) { result in
            if case .success(let url) = result { store.recipe.heightOverrideURL = url }
        }
        .sheet(isPresented: $store.showExportSheet) { ExportSheet(store: store) }
        .sheet(item: $store.metadataEditorSource, onDismiss: {
            store.presentNextMetadataEditor()
        }) { source in
            SourceMetadataEditor(source: source) { label, category in
                store.updateSourceMetadata(id: source.id, label: label, category: category)
                store.metadataEditorSource = nil
            }
        }
        .alert(item: $store.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.destination {
        case .source(let id):
            if let source = store.sources.first(where: { $0.id == id }) {
                MaterialWorkspace(store: store, source: source)
            } else {
                emptyState
            }
        case .inbox:
            CameraInboxView(store: store)
        case .link:
            PairingView(store: store)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Material Selected", systemImage: "square.stack.3d.up")
        } description: {
            Text("Drop photos or textures onto this window, or import them to derive a full PBR material.")
        } actions: {
            Button("Import Images…") { store.showSourceImporter = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.tint.opacity(0.08))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
                .padding(14)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Drop to Import")
                    .font(.title2.weight(.semibold))
                Text("Images become sources · .pbrcapture files go to the Camera Inbox")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop files to import")
    }
}
