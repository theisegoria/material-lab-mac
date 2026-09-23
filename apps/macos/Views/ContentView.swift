import SwiftUI
import UniformTypeIdentifiers

enum SidebarDestination: Hashable {
    case source(String)
    case inbox
    case link
}

struct ContentView: View {
    @Bindable var store: MaterialLabStore
    @State private var destination: SidebarDestination = .inbox

    var body: some View {
        NavigationSplitView {
            SourceSidebar(store: store, selection: $destination)
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 360)
        } detail: {
            Group {
                switch destination {
                case .source(let id):
                    if let source = store.sources.first(where: { $0.id == id }) {
                        MaterialDetail(store: store, source: source)
                    } else {
                        ContentUnavailableView("Source unavailable", systemImage: "photo")
                    }
                case .inbox:
                    CameraInboxView(store: store)
                case .link:
                    PairingView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Import Image", systemImage: "square.and.arrow.down") {
                    store.showSourceImporter = true
                }
                Button("Import Catalog", systemImage: "square.stack.3d.up") {
                    store.showCatalogImporter = true
                }
                if case .source = destination {
                    Button("Derive Maps", systemImage: "wand.and.stars") {
                        store.deriveSelected()
                    }
                    .disabled(store.isBusy || store.selectedSource == nil)
                    Button("Export Bundle", systemImage: "square.and.arrow.up") {
                        store.exportSelected()
                    }
                    .disabled(store.isBusy || store.derived == nil ||
                              store.derived?.source.id != store.selectedSourceID ||
                              store.derived?.recipe != store.recipe)
                }
                if store.isBusy {
                    Button("Cancel", systemImage: "stop.circle") { store.cancel() }
                }
            }
        }
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
        .fileImporter(isPresented: $store.showHeightImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { store.recipe.heightOverrideURL = url }
        }
        .sheet(item: $store.metadataEditorSource, onDismiss: {
            store.presentNextMetadataEditor()
        }) { source in
            SourceMetadataEditor(source: source) { label, category in
                store.updateSourceMetadata(id: source.id, label: label, category: category)
                store.metadataEditorSource = nil
            }
        }
        .alert(item: $store.alert) { item in
            Alert(title: Text("Material Lab"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .onChange(of: store.selectedSourceID) { _, id in
            if let id { destination = .source(id) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if store.isBusy {
                    ProgressView(value: store.progress)
                        .frame(width: 150)
                        .accessibilityLabel("Material processing progress")
                }
                Text(store.status)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Estimates · review before use")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }
}
