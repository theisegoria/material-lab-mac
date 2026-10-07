import AVFoundation
import CoreMotion
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum AppTab: Hashable {
    case capture, material, mac
}

struct CaptureHomeView: View {
    @Bindable var store: CaptureStore
    let link: MacLinkStore
    @State private var selectedTab: AppTab = .capture

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Capture", systemImage: "camera.aperture", value: AppTab.capture) {
                CameraCaptureView(store: store) { selectedTab = .material }
                    .toolbarColorScheme(.dark, for: .tabBar)
            }
            Tab("Material", systemImage: "square.stack.3d.up", value: AppTab.material) {
                NavigationStack {
                    MaterialReviewView(store: store, link: link) { selectedTab = $0 }
                }
            }
            Tab("Mac", systemImage: "laptopcomputer.and.iphone", value: AppTab.mac) {
                NavigationStack {
                    MacLinkView(store: store, link: link)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .alert("Material Capture", isPresented: Binding(get: { store.errorMessage != nil },
                                                       set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: store.importCount)
        .sensoryFeedback(.success, trigger: store.deriveCount)
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
    var symbol: String {
        switch self {
        case .auto: "bolt.badge.automatic"
        case .on: "bolt.fill"
        case .off: "bolt.slash"
        }
    }
    var title: String { L(englishTitle) }
    var englishTitle: String { rawValue.capitalized }
}

/// Device attitude relative to the surface being photographed, from CoreMotion gravity.
@MainActor
@Observable
final class LevelMonitor {
    enum Mode { case flat, upright }
    private(set) var isAvailable = false
    private(set) var mode: Mode = .upright
    /// Flat mode: bubble offset in degrees (x, y). Upright mode: roll in x, pitch in y.
    private(set) var tilt = CGPoint.zero
    private(set) var isLevel = false
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        isAvailable = true
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            self.update(gravity)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    private func update(_ g: CMAcceleration) {
        let degrees = 180.0 / .pi
        if abs(g.z) > 0.75 {
            mode = .flat
            tilt = CGPoint(x: asin(max(-1, min(1, g.x))) * degrees, y: asin(max(-1, min(1, g.y))) * degrees)
            isLevel = hypot(tilt.x, tilt.y) < 3
        } else {
            mode = .upright
            let roll = atan2(g.x, -g.y) * degrees
            let pitch = asin(max(-1, min(1, g.z))) * degrees
            tilt = CGPoint(x: roll, y: pitch)
            isLevel = abs(roll) < 2 && abs(pitch) < 4
        }
    }
}

private struct CameraCaptureView: View {
    let store: CaptureStore
    let onCaptured: () -> Void
    @State private var camera = CameraController()
    @State private var level = LevelMonitor()
    @State private var isReady = false
    @State private var supportsConstantColor = false
    @State private var cameraMessage: String?
    @State private var preferConstantColor = true
    @State private var flash: FlashSetting = .auto
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isCapturing = false
    @State private var shutterCount = 0
    @State private var exposure: ExposureReading?
    @AppStorage("materialCapture.coachSeen") private var coachSeen = false
    @Namespace private var glass

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width - 48, geometry.size.height * 0.52)
            ZStack {
                background
                if isReady {
                    FramingGuide(side: side, isLevel: level.isAvailable ? level.isLevel : nil)
                    if level.isAvailable {
                        LevelIndicator(level: level)
                            .frame(width: 96, height: 96)
                    }
                } else {
                    unavailableContent
                        .padding(.horizontal, 32)
                }
                VStack(spacing: 0) {
                    topControls
                        .padding(.top, 8)
                    Spacer()
                    if isReady {
                        GuidanceHint(message: guidance.message, symbol: guidance.symbol, tone: guidance.tone)
                            .padding(.bottom, 16)
                    }
                    bottomControls
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 20)
                if isReady && !coachSeen {
                    CaptureCoach { withAnimation(.snappy) { coachSeen = true } }
                        .padding(24)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if store.isImporting {
                    ProgressView("Preparing photo…")
                        .padding(20)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.black)
        // The viewfinder is always dark; the rest of the app follows the system appearance.
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.impact(weight: .heavy), trigger: shutterCount)
        .sensoryFeedback(.alignment, trigger: level.isLevel) { _, newValue in newValue }
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
                    Task {
                        if await store.receiveCamera(captured) { onCaptured() }
                    }
                case .failure(let error):
                    // Shown even while the camera stays ready.
                    store.errorMessage = error.localizedDescription
                }
            }
            camera.onExposure = { reading in exposure = reading }
            camera.start()
            level.start()
        }
        .onDisappear {
            camera.stop()
            level.stop()
        }
        .onChange(of: preferConstantColor) { _, enabled in
            if enabled && flash == .off { flash = .auto }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CaptureError.invalidImage
                    }
                    if await store.receive(origin: .photos, data: data) { onCaptured() }
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            Task { await importFile(result) }
        }
    }

    private func importFile(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Refuse oversized files before reading them into memory.
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= SourceImage.maximumImportBytes else { throw CaptureError.importTooLarge }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            if await store.receive(origin: .files, data: data) { onCaptured() }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var background: some View {
        if isReady {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .accessibilityLabel("Live camera with centered square material guide")
        } else {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var unavailableContent: some View {
        if let cameraMessage {
            VStack(spacing: 14) {
                Image(systemName: "camera.badge.ellipsis")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Text("Camera Unavailable")
                    .font(.title2.bold())
                Text(cameraMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Import from Photos or Files to continue without a camera.")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 340)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting camera…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var topControls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if isReady {
                    Menu {
                        Picker("Flash", selection: $flash) {
                            ForEach(FlashSetting.allCases) { setting in
                                Label(setting.title, systemImage: setting.symbol).tag(setting)
                            }
                        }
                    } label: {
                        Image(systemName: flash.symbol)
                            .font(.title3)
                            .frame(width: 48, height: 48)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("flash", in: glass)
                    .accessibilityLabel("Flash")
                    .accessibilityValue(flash.title)
                }
                Spacer(minLength: 0)
                Text("Material Capture")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if isReady {
                    Button {
                        preferConstantColor.toggle()
                    } label: {
                        Image(systemName: preferConstantColor ? "circle.lefthalf.filled" : "circle.dashed")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                    }
                    .glassEffect(preferConstantColor ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                 in: .circle)
                    .glassEffectID("constant-color", in: glass)
                    .disabled(!supportsConstantColor)
                    .accessibilityLabel("Constant Color")
                    .accessibilityValue(preferConstantColor ? "On" : "Off")
                    .accessibilityHint(supportsConstantColor
                        ? "Uses flash to cancel ambient light; falls back if confidence is low"
                        : "Constant Color is unavailable on this camera")
                }
            }
        }
    }

    private var bottomControls: some View {
        GlassEffectContainer(spacing: 28) {
            HStack(alignment: .center, spacing: 36) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Photos")

                if isReady {
                    ShutterButton(isBusy: isCapturing) {
                        isCapturing = true
                        shutterCount += 1
                        camera.capture(preferConstantColor: preferConstantColor, flash: flash.captureMode)
                    }
                    .disabled(isCapturing)
                } else {
                    Circle()
                        .strokeBorder(.white.opacity(0.25), lineWidth: 4)
                        .frame(width: 84, height: 84)
                        .accessibilityHidden(true)
                }

                Button { showFileImporter = true } label: {
                    Label("Files", systemImage: "folder")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Files")
            }
        }
    }

    private var guidance: (message: String, symbol: String, tone: GuidanceHint.Tone) {
        if let exposure {
            if exposure.clippedFraction > 0.03 {
                return ("Glare detected — tilt slightly or soften the light", "sun.max.trianglebadge.exclamationmark", .warning)
            }
            if exposure.meanLuma < 0.12 { return ("Too dark — add even, diffuse light", "moon", .warning) }
        }
        if level.isAvailable && !level.isLevel {
            return (level.mode == .flat ? "Hold the phone parallel to the surface" : "Level the phone with the surface",
                    "level", .neutral)
        }
        return ("Fill the square with one evenly lit surface", "checkmark.circle", .good)
    }
}

private struct ShutterButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 5).frame(width: 84, height: 84)
                if isBusy {
                    ProgressView().tint(.black)
                        .frame(width: 68, height: 68)
                        .background(.white.opacity(0.85), in: .circle)
                } else {
                    Circle().fill(.white).frame(width: 68, height: 68)
                }
            }
        }
        .buttonStyle(ShutterPressStyle())
        .accessibilityLabel("Capture Material")
        .accessibilityIdentifier("capture-material")
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct FramingGuide: View {
    let side: CGFloat
    let isLevel: Bool?

    var body: some View {
        let color: Color = isLevel == true ? .green : .white
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.28))
                .reverseMask { RoundedRectangle(cornerRadius: 18).frame(width: side, height: side) }
                .ignoresSafeArea()
            CornerBrackets()
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .animation(.easeInOut(duration: 0.2), value: isLevel)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay { mask().blendMode(.destinationOut) }
                .compositingGroup()
        }
    }
}

private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.14
        let radius: CGFloat = 18
        var path = Path()
        // Top left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        // Top right
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        // Bottom right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        // Bottom left
        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}

private struct LevelIndicator: View {
    let level: LevelMonitor

    var body: some View {
        let color: Color = level.isLevel ? .green : .white
        ZStack {
            switch level.mode {
            case .flat:
                Circle().stroke(color.opacity(0.7), lineWidth: 1.5).frame(width: 44, height: 44)
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .offset(x: max(-40, min(40, level.tilt.x * 2)), y: max(-40, min(40, -level.tilt.y * 2)))
            case .upright:
                Capsule()
                    .fill(color)
                    .frame(width: 88, height: 3)
                    .rotationEffect(.degrees(-level.tilt.x))
                    .offset(y: max(-36, min(36, level.tilt.y * 2)))
                Capsule().fill(color.opacity(0.5)).frame(width: 20, height: 3)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .animation(.interactiveSpring, value: level.tilt)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(level.isLevel ? "Level" : String(format: "Tilted %.0f degrees",
                                                             max(abs(level.tilt.x), abs(level.tilt.y))))
    }
}

private struct GuidanceHint: View {
    enum Tone { case good, neutral, warning }
    let message: String
    let symbol: String
    let tone: Tone

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tone == .warning ? Color.yellow : Color.white)
            .symbolRenderingMode(.hierarchical)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: message)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// First-launch tips for a good material photo.
private struct CaptureCoach: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Three tips for a great material")
                .font(.title3.weight(.semibold))
            tip("square.dashed", "Fill the frame", "Get close so the surface fills the guide; the corners can be adjusted later.")
            tip("sun.max.trianglebadge.exclamationmark", "Avoid glare", "Soft, even light works best. Turn away from bright reflections.")
            tip("camera.metering.center.weighted", "Shoot straight on", "Hold the phone parallel to the surface; the level turns green.")
            Button {
                dismiss()
            } label: {
                Text("Got It").frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("capture-coach-done")
        }
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
    }

    private func tip(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
