import SwiftUI

/// Full-screen four-corner editor. Edits apply live so the preview re-derives as corners settle.
struct CropEditorView: View {
    @Bindable var store: CaptureStore
    let image: CGImage
    @Environment(\.dismiss) private var dismiss
    @State private var original: PerspectiveQuad?
    @State private var isDetecting = false
    @State private var detectFailed = 0
    @State private var detectSucceeded = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                PerspectiveCropView(image: image, quad: $store.crop)
                    .padding(20)
                    .padding(.bottom, 90)
                VStack {
                    Spacer()
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    isDetecting = true
                                    if await store.autoDetectCrop() { detectSucceeded += 1 } else { detectFailed += 1 }
                                    isDetecting = false
                                }
                            } label: {
                                Label(isDetecting ? "Detecting…" : "Auto-Detect", systemImage: "viewfinder")
                                    .frame(minHeight: 32)
                            }
                            .buttonStyle(.glass)
                            .disabled(isDetecting)
                            .accessibilityIdentifier("auto-detect-crop")

                            Button {
                                store.resetCrop()
                            } label: {
                                Label("Square", systemImage: "square.dashed")
                                    .frame(minHeight: 32)
                            }
                            .buttonStyle(.glass)

                            Button {
                                store.crop = .full
                            } label: {
                                Label("Full", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .frame(minHeight: 32)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    if detectFailed > 0 {
                        Text("No rectangular surface found. Drag the corners instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                }
            }
            .environment(\.colorScheme, .dark)
            .navigationTitle("Perspective Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        if let original { store.crop = original }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .disabled(!store.crop.isValid)
                        .accessibilityIdentifier("crop-done")
                }
            }
            .sensoryFeedback(.success, trigger: detectSucceeded)
            .sensoryFeedback(.error, trigger: detectFailed)
        }
        .onAppear { if original == nil { original = store.crop } }
    }
}
