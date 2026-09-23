import SwiftUI

struct CameraInboxView: View {
    @Bindable var store: MaterialLabStore

    private var captures: [MaterialSource] {
        store.sources.filter { $0.origin == .cameraInbox }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Camera Inbox").font(.largeTitle.bold())
                Text("Import captures from Material Capture on iPhone. Source images and envelopes stay in this local inbox, separate from any game catalog.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Import Capture File…") { store.showBundleImporter = true }
                        .buttonStyle(.borderedProminent)
                    Button("Refresh Inbox") { store.refreshInbox() }
                    Button("Open Inbox in Finder") {
                        NSWorkspace.shared.open(MaterialLibrary.inbox)
                    }
                }
                if captures.isEmpty {
                    ContentUnavailableView(
                        "No captures yet",
                        systemImage: "camera",
                        description: Text("Use Files or AirDrop to import a .pbrcapture file. Direct device linking appears in Device Link.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ForEach(captures) { capture in
                        Button {
                            store.selectSource(capture.id)
                        } label: {
                            HStack {
                                Image(systemName: "photo").font(.title2)
                                VStack(alignment: .leading) {
                                    Text(capture.displayName).font(.headline)
                                    Text(capture.category).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Captures are checksum verified. Camera albedo and derived maps remain estimates until reviewed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
