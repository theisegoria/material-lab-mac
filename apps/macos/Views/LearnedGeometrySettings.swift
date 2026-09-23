import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings (⌘,) root. One pane today; tabs keep room for more.
struct MaterialLabSettings: View {
    let learned: LearnedModelStore

    var body: some View {
        TabView {
            Tab("Learned Geometry", systemImage: "sparkles") {
                LearnedGeometrySettings(learned: learned)
            }
        }
        .frame(width: 520, height: 560)
    }
}

/// Installs, inspects and configures the optional MoGe-2 normal estimator.
struct LearnedGeometrySettings: View {
    @Bindable var learned: LearnedModelStore

    var body: some View {
        Form {
            Section {
                header
                if let info = learned.info {
                    LabeledContent("Model", value: info.origin == .builtIn ? "\(info.modelFile) (built in)" : info.modelFile)
                    LabeledContent("Weights SHA-256") { mono(info.weightsSHA256) }
                    LabeledContent("MoGe commit") { mono(info.mogeCommit) }
                    LabeledContent("Contract") { mono(LearnedNormalEstimator.contract) }
                }
                if let error = learned.lastError ?? failure {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if learned.info?.origin == .installed {
                        Button(learned.hasBuiltInModel ? "Revert to Built-in" : "Remove",
                               role: learned.hasBuiltInModel ? nil : .destructive) {
                            Task { await learned.uninstall() }
                        }
                    }
                    Spacer()
                    Button(installTitle) { chooseModel() }
                        .buttonStyle(.borderedProminent)
                        .disabled(learned.status == .installing)
                }
            } footer: {
                Text(learned.info?.origin == .builtIn
                     ? "Material Lab includes this model. A model you install takes precedence and is kept in ~/Library/Application Support/Material Lab/Models."
                     : "Choose MoGe2Normals.mlpackage (or a compiled .mlmodelc). It is compiled once and kept in ~/Library/Application Support/Material Lab/Models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Compute units", selection: $learned.cpuOnly) {
                    Text("Neural Engine (recommended)").tag(false)
                    Text("CPU only").tag(true)
                }
                if let seconds = learned.lastInferenceDuration {
                    LabeledContent("Last estimate", value: "\(Int((seconds * 1000).rounded())) ms")
                }
            } header: {
                Text("Performance")
            } footer: {
                Text("The Neural Engine runs in half precision, so results can differ slightly between chips and macOS versions. CPU only is slower but more reproducible. Estimates are cached per source, so recipe edits never re-run the model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Licences") {
                Text(LearnedModelStore.attribution)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var installTitle: String {
        switch learned.info?.origin {
        case .none: "Install Model…"
        case .installed?: "Replace Model…"
        case .builtIn?, .environment?: "Use a Different Model…"
        }
    }

    private var failure: String? {
        if case .failed(let message) = learned.status { return message }
        return nil
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("MoGe-2 Learned Normals").font(.headline)
                Text("Monocular geometry that reads recesses a luminance heuristic gets wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            StatusBadge(title: learned.statusTitle, tint: tint, busy: busy)
        }
        .padding(.vertical, 4)
    }

    private var busy: Bool {
        learned.status == .installing || learned.status == .loading || learned.isRunning
    }

    private var tint: Color {
        switch learned.status {
        case .ready: learned.isRunning ? .purple : .green
        case .installing, .loading: .blue
        case .notInstalled: .secondary
        case .failed: .orange
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text.count > 16 ? String(text.prefix(16)) + "…" : text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .help(text)
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Install Learned Normal Model"
        panel.message = "Choose a MoGe-2 Core ML model (.mlpackage or .mlmodelc)."
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        // Model packages are directories whose UTType may be unregistered; the extension is checked on install.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await learned.install(from: url) }
    }
}

private struct StatusBadge: View {
    let title: String
    let tint: Color
    let busy: Bool

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay { Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model status: \(title)")
    }
}
