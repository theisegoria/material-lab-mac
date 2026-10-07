import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// "Your maps": mark the photo as a hand-made albedo and bring artist-made height, normal, roughness, occlusion or
/// metalness maps from Photos or Files. Anything added replaces the estimate and is recorded as authored.
struct AuthoredMapsSection: View {
    @Bindable var store: CaptureStore
    @State private var role: AuthoredMaps.Role?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { store.authored.handMadeAlbedo }, set: { store.setHandMadeAlbedo($0) })) {
                Label("Hand-made albedo", systemImage: "paintbrush.pointed")
            }
            .accessibilityIdentifier("hand-made-albedo")
            ForEach(AuthoredMaps.Role.allCases) { role in
                Menu {
                    Button("Choose from Photos", systemImage: "photo.on.rectangle") { choose(role, photos: true) }
                    Button("Choose from Files", systemImage: "folder") { choose(role, photos: false) }
                    if store.authored.maps[role] != nil {
                        Button("Remove", systemImage: "trash", role: .destructive) { store.removeAuthoredMap(role) }
                    }
                } label: {
                    LabeledContent {
                        Text(store.authored.maps[role]?.name ?? "Estimated")
                            .foregroundStyle(store.authored.maps[role] == nil ? .secondary : .primary)
                            .lineLimit(1)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(role.title).foregroundStyle(.primary)
                                Text(role.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: role.symbol)
                        }
                    }
                }
                .accessibilityIdentifier("authored-\(role.rawValue)")
                if role == .normal, store.authored.maps[.normal] != nil {
                    Toggle("DirectX normal map (green down)",
                           isOn: Binding(get: { store.authored.normalDirectX }, set: { store.setNormalMapDirectX($0) }))
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Your maps")
        } footer: {
            Text("Bring your own artwork. A hand-made albedo is used whole, without perspective correction. Each map you add replaces the estimate and is recorded as authored in exported bundles (the .pbrcapture for the Mac carries the photo and recipe only).")
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images, photoLibrary: .shared())
        .onChange(of: photoItem) {
            guard let item = photoItem, let role else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    store.errorMessage = "That photo could not be loaded."
                    return
                }
                store.setAuthoredMap(role, data: data, name: "\(role.rawValue) (Photos)")
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            guard let role, case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                store.errorMessage = "That file could not be read."
                return
            }
            store.setAuthoredMap(role, data: data, name: url.lastPathComponent)
        }
    }

    private func choose(_ role: AuthoredMaps.Role, photos: Bool) {
        self.role = role
        if photos { showPhotos = true } else { showFiles = true }
    }
}
