import Foundation
import Observation

/// Main-actor state for the optional learned normal estimator: installation, compute units and
/// inference progress. The heavy work lives in LearnedNormalEstimator.
@MainActor
@Observable
final class LearnedModelStore {
    enum Status: Equatable {
        case notInstalled
        case installing
        case loading
        case ready
        case failed(String)
    }

    private(set) var status: Status = .notInstalled
    private(set) var info: LearnedModelInfo?
    /// Tile progress of a running inference, nil when idle.
    var inferenceProgress: Float?
    /// Pass count and time left for the running inference (nil when idle).
    var inferenceDetail: LearnedProgress?
    var lastInferenceDuration: TimeInterval?
    var cpuOnly = UserDefaults.standard.bool(forKey: "materialLab.learnedCPUOnly") {
        didSet {
            guard cpuOnly != oldValue else { return }
            UserDefaults.standard.set(cpuOnly, forKey: "materialLab.learnedCPUOnly")
            LearnedNormalEstimator.shared.computeUnits = cpuOnly ? .cpuOnly : .all
            warmUp()
            onModelChanged?()
        }
    }
    var showImporter = false

    /// Called after the model or compute units change so the current derivation can refresh.
    @ObservationIgnored var onModelChanged: (() -> Void)?

    static let environmentKey = LearnedNormalEstimator.environmentKey

    var isInstalled: Bool { info != nil }
    var isRunning: Bool { inferenceProgress != nil }

    var statusTitle: String {
        switch status {
        case .notInstalled: "Not installed"
        case .installing: "Installing…"
        case .loading: "Preparing…"
        case .ready:
            if isRunning { "Running…" }
            else if info?.origin == .builtIn { "Built in" }
            else if info?.origin == .environment { "Developer model" }
            else { "Ready" }
        case .failed: "Unavailable"
        }
    }

    init() {
        LearnedNormalEstimator.shared.computeUnits = cpuOnly ? .cpuOnly : .all
    }

    /// A model ships inside the app bundle (Contents/Resources/Models).
    let hasBuiltInModel = LearnedNormalEstimator.bundledModelURL != nil

    /// Resolves the active model: user-installed, then built in, then MATERIAL_LAB_MOGE_MODEL.
    func bootstrap() {
        Task { await resolve() }
    }

    /// True once the first model resolution has finished.
    private(set) var hasResolved = false

    private func resolve() async {
        defer { hasResolved = true }
        let result: Result<LearnedModelInfo?, Error>
        do { result = .success(try await LearnedNormalEstimator.shared.resolveModel()) }
        catch { result = .failure(error) }
        switch result {
        case .success(let loaded?):
            info = loaded
            status = .ready
            warmUp()
        case .success(nil):
            info = nil
            status = .notInstalled
        case .failure(let error):
            info = nil
            status = .failed(error.localizedDescription)
        }
    }

    func install(from url: URL) async {
        status = .installing
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        lastError = nil
        do {
            let installed = try await LearnedNormalEstimator.shared.install(from: url)
            info = installed
            status = .ready
            warmUp()
            onModelChanged?()
        } catch {
            // A failed install leaves any previously installed model in place.
            status = info == nil ? .failed(error.localizedDescription) : .ready
            lastError = error.localizedDescription
        }
    }

    /// The most recent install failure, shown in Settings.
    var lastError: String?

    /// Removes the user-installed model and falls back to the built-in (or developer) model, if any.
    func uninstall() async {
        LearnedNormalEstimator.shared.uninstall()
        info = nil
        status = .notInstalled
        await resolve()
        onModelChanged?()
    }

    /// Shows the "no model" state without removing files (snapshot harness only).
    func deactivateForSnapshot() {
        LearnedNormalEstimator.shared.deactivate()
        info = nil
        status = .notInstalled
    }

    /// Loads the model for the current compute units in the background so the first slider move is quick.
    func warmUp() {
        guard info != nil else { return }
        let wasReady = status == .ready
        if !wasReady { status = .loading }
        Task.detached(priority: .utility) {
            _ = try? LearnedNormalEstimator.shared.prepare()
            await MainActor.run { [weak self] in
                if self?.status == .loading { self?.status = .ready }
            }
        }
    }

    static let attribution = """
    Learned geometry uses Microsoft MoGe-2 (ViT-S, normal head), converted to Core ML and run \
    entirely on this Mac. MoGe code and weights: MIT License, © Microsoft Corporation. \
    DINOv2 modules: Apache License 2.0, © Meta Platforms, Inc. Nothing is downloaded at runtime.
    """
}
