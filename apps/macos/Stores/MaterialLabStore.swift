import AppKit
import Foundation
import Observation

struct MaterialAlert: Identifiable {
    let id = UUID()
    let message: String
}

@MainActor
@Observable
final class MaterialLabStore {
    var sources: [MaterialSource] = []
    var selectedSourceID: String?
    var searchText = ""
    var recipe = MaterialEngine.defaultRecipe(for: .flat)
    var selectedMap: MaterialMapKind = .albedo
    var derived: DerivedMaterial?
    var derivationSerial = 0
    var progress: Float = 0
    var status = "Import a source image or material catalog to begin."
    var isBusy = false
    var showSourceImporter = false
    var showCatalogImporter = false
    var showBundleImporter = false
    var showReliefImporter = false
    var showHeightImporter = false
    var alert: MaterialAlert?
    var lastExportURL: URL?
    var includeUnreviewedBatch = false
    var metadataEditorSource: MaterialSource?
    let link = LocalLinkService()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var activeControl: DerivationControl?
    @ObservationIgnored private var pendingMetadataSources: [MaterialSource] = []

    var selectedSource: MaterialSource? {
        sources.first { $0.id == selectedSourceID }
    }

    var filteredSources: [MaterialSource] {
        guard !searchText.isEmpty else { return sources }
        return sources.filter {
            $0.semanticLabel.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var inboxCount: Int { sources.filter { $0.origin == .cameraInbox }.count }

    var eligibleBatchSources: [MaterialSource] {
        filteredSources.filter { source in
            if includeUnreviewedBatch { return true }
            let status = source.reviewStatus.lowercased()
            return status.contains("reviewed") && !status.contains("unreviewed") ||
                   status.contains("approved")
        }
    }

    func bootstrap() {
        guard !started else { return }
        started = true
        do {
            try MaterialLibrary.prepareDirectories()
            link.onImported = { [weak self] source in
                guard let self else { return }
                self.sources.append(source)
                self.deduplicateAndSort()
                self.selectedSourceID = source.id
                self.status = "Capture imported from iPhone and checksum verified."
            }
            sources = MaterialLibrary.loadSavedSources() + MaterialLibrary.loadInbox()
            if let savedCatalog = UserDefaults.standard.string(forKey: "materialLab.catalogPath") {
                let url = URL(fileURLWithPath: savedCatalog)
                if FileManager.default.fileExists(atPath: url.path) {
                    sources += (try? MaterialLibrary.importCatalog(url)) ?? []
                }
            }
            sources = MaterialLibrary.applyMetadataOverrides(sources)
            deduplicateAndSort()
            selectedSourceID = sources.first?.id
            status = sources.isEmpty
                ? "Import a source image or material catalog to begin."
                : "\(sources.count) source images ready. Select one to derive maps."
        } catch {
            alert = MaterialAlert(message: error.localizedDescription)
        }
    }

    func importSources(_ urls: [URL]) {
        do {
            var imported: [MaterialSource] = []
            for url in urls {
                let copy = try MaterialLibrary.copyImportedSource(url)
                sources.append(copy)
                imported.append(copy)
            }
            deduplicateAndSort()
            try MaterialLibrary.saveImportedSources(sources)
            selectedSourceID = imported.last?.id
            derived = nil
            pendingMetadataSources.append(contentsOf: imported)
            presentNextMetadataEditor()
            status = "\(imported.count) source image(s) imported. Add semantic labels before deriving."
        } catch {
            alert = MaterialAlert(message: error.localizedDescription)
        }
    }

    func importCatalog(_ url: URL) {
        do {
            let catalog = MaterialLibrary.applyMetadataOverrides(try MaterialLibrary.importCatalog(url))
            sources.removeAll { $0.origin == .catalog }
            sources.append(contentsOf: catalog)
            deduplicateAndSort()
            UserDefaults.standard.set(url.path, forKey: "materialLab.catalogPath")
            selectedSourceID = catalog.first?.id
            derived = nil
            status = "\(catalog.count) catalog entries available; review status remains visible."
        } catch {
            alert = MaterialAlert(message: error.localizedDescription)
        }
    }

    func importCapture(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let source = try MaterialBundle.importCapture(data)
            sources.append(source)
            deduplicateAndSort()
            selectedSourceID = source.id
            derived = nil
            status = "Capture imported and checksum verified."
        } catch {
            alert = MaterialAlert(message: error.localizedDescription)
        }
    }

    func refreshInbox() {
        sources.removeAll { $0.origin == .cameraInbox }
        sources.append(contentsOf: MaterialLibrary.applyMetadataOverrides(MaterialLibrary.loadInbox()))
        deduplicateAndSort()
        status = "\(inboxCount) camera capture(s) in the inbox."
    }

    func selectSource(_ id: String?) {
        guard selectedSourceID != id else { return }
        if isBusy { activeControl?.cancel() }
        selectedSourceID = id
        derived = nil
        selectedMap = .albedo
        recipe = MaterialEngine.defaultRecipe(for: .flat)
    }

    func presentNextMetadataEditor() {
        guard metadataEditorSource == nil, !pendingMetadataSources.isEmpty else { return }
        metadataEditorSource = pendingMetadataSources.removeFirst()
    }

    func editMetadata(for source: MaterialSource) {
        metadataEditorSource = source
    }

    func updateSourceMetadata(id: String, label: String, category: String) {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty, cleanLabel.count <= 240,
              !cleanCategory.isEmpty, cleanCategory.count <= 120,
              let index = sources.firstIndex(where: { $0.id == id }) else {
            alert = MaterialAlert(message: "Enter a semantic label and category before saving.")
            return
        }
        let prior = sources[index]
        let updated = MaterialSource(
            id: prior.id, url: prior.url,
            semanticLabel: cleanLabel, category: cleanCategory,
            origin: prior.origin, reviewStatus: prior.reviewStatus,
            originalEnvelopeURL: prior.originalEnvelopeURL
        )
        do {
            try MaterialLibrary.saveMetadataOverride(updated)
            sources[index] = updated
            if updated.origin == .imported {
                try MaterialLibrary.saveImportedSources(sources)
            }
            if selectedSourceID == id {
                activeControl?.cancel()
                derived = nil
            }
            deduplicateAndSort()
            status = "Semantic label saved for \(cleanLabel). Derive again to export under this label."
        } catch {
            alert = MaterialAlert(message: error.localizedDescription)
        }
    }

    func choosePreset(_ preset: MaterialPreset) {
        let mask = recipe.reliefMaskURL
        let height = recipe.heightOverrideURL
        recipe = MaterialEngine.defaultRecipe(for: preset)
        recipe.reliefMaskURL = mask
        recipe.heightOverrideURL = height
        derived = nil
    }

    func deriveSelected() {
        guard let source = selectedSource, !isBusy else { return }
        let chosenRecipe = recipe
        let control = DerivationControl { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        activeControl = control
        progress = 0
        isBusy = true
        status = "Deriving maps for \(source.displayName)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let value = try MaterialEngine.derive(
                    source: source, recipe: chosenRecipe, control: control
                )
                await MainActor.run {
                    guard let self else { return }
                    self.isBusy = false
                    self.activeControl = nil
                    guard self.selectedSourceID == source.id,
                          self.recipe == chosenRecipe else {
                        self.status = "Selection or recipe changed. Derive the current source again."
                        return
                    }
                    self.derived = value
                    self.derivationSerial += 1
                    self.progress = 1
                    self.status = "Derived \(value.maps.count) maps. Review seams and provenance before export."
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.activeControl = nil
                    self?.status = control.shouldContinue ? "Derivation failed." : "Derivation cancelled."
                    if control.shouldContinue {
                        self?.alert = MaterialAlert(message: error.localizedDescription)
                    }
                }
            }
        }
    }

    func cancel() {
        activeControl?.cancel()
        status = "Cancelling after the current processing step…"
    }

    func exportSelected() {
        guard let derived, derived.source.id == selectedSourceID,
              derived.recipe == recipe, !isBusy,
              let destination = chooseDestination() else { return }
        isBusy = true
        status = "Exporting validated PNG maps and manifest…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try MaterialBundle.export(derived, into: destination)
                await MainActor.run {
                    self?.lastExportURL = url
                    self?.status = "Exported material bundle to \(url.lastPathComponent)."
                    self?.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.alert = MaterialAlert(message: error.localizedDescription)
                }
            }
        }
    }

    func batchDeriveVisible() {
        guard !isBusy, !eligibleBatchSources.isEmpty, let destination = chooseDestination() else { return }
        let targets = eligibleBatchSources
        let chosenRecipe = recipe
        isBusy = true
        progress = 0
        status = "Starting batch of \(targets.count) source images…"
        let control = DerivationControl { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                let completed = self.batchCompleted
                self.progress = (Float(completed) + value) / Float(max(1, targets.count))
            }
        }
        activeControl = control
        batchCompleted = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            var failures: [String] = []
            var finished = 0
            for source in targets {
                if !control.shouldContinue { break }
                do {
                    let result = try MaterialEngine.derive(
                        source: source, recipe: chosenRecipe, control: control
                    )
                    _ = try MaterialBundle.export(result, into: destination)
                    finished += 1
                } catch {
                    if !control.shouldContinue { break }
                    failures.append("\(source.displayName): \(error.localizedDescription)")
                }
                await MainActor.run {
                    self?.batchCompleted += 1
                    self?.progress = Float(self?.batchCompleted ?? 0) / Float(max(1, targets.count))
                    self?.status = "Batch \(self?.batchCompleted ?? 0) / \(targets.count)"
                }
            }
            await MainActor.run {
                self?.isBusy = false
                self?.activeControl = nil
                self?.status = control.shouldContinue
                    ? "Batch complete: \(finished) exported, \(failures.count) failed."
                    : "Batch cancelled after \(finished) exports."
                if !failures.isEmpty {
                    self?.alert = MaterialAlert(message: failures.prefix(5).joined(separator: "\n"))
                }
            }
        }
    }

    @ObservationIgnored private var batchCompleted = 0

    private func deduplicateAndSort() {
        var seen = Set<String>()
        sources = sources.filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.origin != $1.origin { return $0.origin.rawValue < $1.origin.rawValue }
                return $0.semanticLabel.localizedStandardCompare($1.semanticLabel) == .orderedAscending
            }
    }

    private func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an export folder"
        panel.message = "Material Lab creates a separate .pbrmaterial bundle for each source."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
