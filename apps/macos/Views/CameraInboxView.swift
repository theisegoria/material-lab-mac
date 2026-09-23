import AppKit
import SwiftUI

struct CameraInboxView: View {
    @Bindable var store: MaterialLabStore

    private var captures: [MaterialSource] {
        store.sources.filter { $0.origin == .cameraInbox }
    }

    var body: some View {
        Group {
            if captures.isEmpty {
                ContentUnavailableView {
                    Label("No Captures Yet", systemImage: "camera.on.rectangle")
                } description: {
                    Text("Send a capture from Material Capture on iPhone through Device Link, or drop a .pbrcapture file here.")
                } actions: {
                    HStack {
                        Button("Import Capture…") { store.showBundleImporter = true }
                            .buttonStyle(.glassProminent)
                        Button("Set Up Device Link") { store.navigate(to: .link) }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Captures are checksum-verified on arrival. Camera albedo and derived maps remain estimates until reviewed.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 640, alignment: .leading)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 18)],
                                  spacing: 18) {
                            ForEach(captures) { capture in
                                CaptureCard(capture: capture, isSelected: capture.id == store.selectedSource?.id) {
                                    // Always navigate, even when this capture is already selected.
                                    store.navigate(to: .source(capture.id))
                                }
                            }
                        }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle("Camera Inbox")
        .navigationSubtitle(captures.isEmpty ? "" : "\(captures.count) capture\(captures.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { store.refreshInbox() }
                    .help("Reload the inbox folder")
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(MaterialLibrary.inbox)
                }
                .help("Open the inbox folder in Finder")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Import Capture…", systemImage: "square.and.arrow.down") {
                    store.showBundleImporter = true
                }
                .buttonStyle(.glassProminent)
            }
        }
    }
}

private struct CaptureCard: View {
    let capture: MaterialSource
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geometry in
                    SourceThumbnail(url: capture.url, side: geometry.size.width, cornerRadius: 12, maxPixel: 520)
                }
                .aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(capture.category)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quinary))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .accessibilityLabel("\(capture.displayName), \(capture.category)")
        .accessibilityHint("Opens the capture in the material workspace")
    }
}
