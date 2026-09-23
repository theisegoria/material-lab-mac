import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private enum CaptureTab: Hashable {
    case capture, material
}

struct CaptureHomeView: View {
    let store: CaptureStore
    @State private var selectedTab: CaptureTab = .capture

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CameraCaptureView(store: store) { selectedTab = .material }
            }
            .tabItem { Label("Capture", systemImage: "camera") }
            .tag(CaptureTab.capture)

            NavigationStack {
                MaterialReviewView(store: store)
            }
            .tabItem { Label("Material", systemImage: "square.stack.3d.up") }
            .tag(CaptureTab.material)
        }
    }
}

private enum FlashSetting: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var captureMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: .auto
        case .on: .on
        case .off: .off
        }
    }
}

private struct CameraCaptureView: View {
    let store: CaptureStore
    let onCaptured: () -> Void
    @State private var camera = CameraController()
    @State private var isReady = false
    @State private var supportsConstantColor = false
    @State private var cameraMessage: String?
    @State private var preferConstantColor = true
    @State private var flash: FlashSetting = .auto
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isCapturing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    CameraPreview(session: camera.session)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [10, 7]))
                        .padding(28)
                        .allowsHitTesting(false)
                    if !isReady {
                        Text(cameraMessage ?? "Starting camera…")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(30)
                    }
                }
                .accessibilityLabel("Live camera with centered square material guide")

                Text("Fill the square with one evenly lit surface. Hold the phone parallel, avoid glare and cast shadows, then refine the corners after capture.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if isReady {
                    Toggle("Prefer Constant Color", isOn: $preferConstantColor)
                        .disabled(!supportsConstantColor)
                        .accessibilityHint("Uses flash and may take several seconds; falls back if crop confidence is low")
                    if !supportsConstantColor {
                        Text("Constant Color is unavailable on this camera. Capture will be labeled estimated albedo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Flash", selection: $flash) {
                        ForEach(FlashSetting.allCases) { setting in
                            Text(setting.rawValue.capitalized).tag(setting)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        isCapturing = true
                        camera.capture(preferConstantColor: preferConstantColor, flash: flash.captureMode)
                    } label: {
                        if isCapturing {
                            HStack { ProgressView(); Text("Capturing…") }
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Capture Material", systemImage: "camera.shutter.button")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isReady || isCapturing)
                    .accessibilityIdentifier("capture-material")
                } else if cameraMessage != nil {
                    Text("Import from Photos or Files to continue without a camera.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Photos", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                    Button { showFileImporter = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .navigationTitle("Material Capture")
        .task {
            camera.onReady = { result in
                switch result {
                case .success(let supported):
                    isReady = true
                    supportsConstantColor = supported
                    preferConstantColor = supported
                    cameraMessage = nil
                case .failure(let error):
                    isReady = false
                    supportsConstantColor = false
                    preferConstantColor = false
                    cameraMessage = error.localizedDescription
                }
            }
            camera.onCapture = { result in
                isCapturing = false
                switch result {
                case .success(let captured):
                    store.receiveCamera(captured)
                    onCaptured()
                case .failure(let error):
                    cameraMessage = error.localizedDescription
                }
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: preferConstantColor) { _, enabled in
            if enabled && flash == .off { flash = .auto }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CaptureError.invalidImage
                    }
                    store.receive(origin: .photos, data: data)
                    onCaptured()
                } catch { cameraMessage = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                store.receive(origin: .files, data: try Data(contentsOf: url))
                onCaptured()
            } catch { cameraMessage = error.localizedDescription }
        }
    }
}
