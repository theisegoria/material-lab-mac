import AppKit
import Foundation

/// Watch folder: photos dropped into a chosen folder are derived with a saved recipe and exported with chosen
/// formats through the batch queue (status and pause/resume live in the Batch Queue window).
extension MaterialLabStore {
    /// The recipe new photos derive with: the chosen saved recipe, or the default flat recipe.
    var watchRecipe: MaterialRecipe {
        if let id = watchSettings.recipeID, let saved = savedRecipes.first(where: { $0.id == id }) { return saved.recipe }
        return MaterialEngine.defaultRecipe(for: .flat)
    }

    var watchRecipeTitle: String {
        if let id = watchSettings.recipeID, let saved = savedRecipes.first(where: { $0.id == id }) { return saved.name }
        return String(localized: "Default (Flat)")
    }

    func startWatchingFromPreferences() {
        // Verification runs never pick up real folders.
        guard !SnapshotHarness.isActive, !SnapshotHarness.isStaging, let folder = watchSettings.folderURL else { return }
        configureWatchCallbacks()
        watch.start(folder, paused: watchSettings.paused)
    }

    /// Chooses the folder to watch. Photos already in it are left alone; only new ones are processed.
    func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Folder to Watch")
        panel.message = String(localized: "New photos added to this folder are derived and exported automatically.")
        panel.prompt = String(localized: "Watch")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var settings = watchSettings
        settings.folderPath = url.path
        if settings.formats.isEmpty { settings.formats = exportTargets.sorted() }
        settings.paused = false
        settings.seen = [:]
        for photo in WatchFolderService.photos(in: url) { settings.seen[photo.url.lastPathComponent] = photo.modified }
        watchSettings = settings
        configureWatchCallbacks()
        watch.start(url, paused: false)
        status = "Watching \(url.lastPathComponent). New photos are derived with “\(watchRecipeTitle)”."
    }

    func chooseWatchOutput() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Where Watched Photos Export")
        panel.prompt = String(localized: "Export Here")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let folder = watchSettings.folderURL, url.standardizedFileURL == folder.standardizedFileURL {
            // Bundles are directories, so the scan would skip them, but keep exports out of the inbox folder anyway.
            watchSettings.outputPath = nil
        } else {
            watchSettings.outputPath = url.path
        }
    }

    func setWatchPaused(_ paused: Bool) {
        watchSettings.paused = paused
        watch.setPaused(paused)
        status = paused ? "Watch folder paused. New photos wait until you resume."
                        : "Watch folder resumed."
    }

    func stopWatching() {
        watch.stop()
        watchSettings = WatchFolderSettings(formats: watchSettings.formats)
        status = "Stopped watching the folder."
    }

    func toggleWatchFormat(_ id: String) {
        if let index = watchSettings.formats.firstIndex(of: id) { watchSettings.formats.remove(at: index) }
        else { watchSettings.formats.append(id) }
    }

    private func configureWatchCallbacks() {
        watch.isSeen = { [weak self] name, modified in
            guard let seen = self?.watchSettings.seen[name] else { return false }
            return abs(seen - modified) < 1
        }
        watch.onNewFiles = { [weak self] urls in self?.processWatchedPhotos(urls) }
    }

    private func processWatchedPhotos(_ urls: [URL]) {
        guard let output = watchSettings.outputURL else { return }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            status = "Watch folder: cannot create the export folder (\(error.localizedDescription))."
            return
        }
        let recipe = watchRecipe
        let formats = ExportTarget.named(watchSettings.formats)
        var settings = watchSettings
        let items = urls.map { url -> BatchItem in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            settings.seen[url.lastPathComponent] = modified
            let source = MaterialSource(
                id: "watch:\(url.path)", url: url,
                semanticLabel: url.deletingPathExtension().lastPathComponent,
                category: "watch folder", origin: .imported, reviewStatus: "unreviewed",
                originalEnvelopeURL: nil
            )
            return BatchItem(source: source, recipe: recipe, destination: output, formats: formats, origin: .watchFolder)
        }
        watchSettings = settings
        enqueueBatch(items)
        status = "Watch folder: queued \(items.count) new photo\(items.count == 1 ? "" : "s")."
    }
}
