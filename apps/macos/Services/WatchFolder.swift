import Foundation
import Observation
import UniformTypeIdentifiers

/// What the watch folder does with new photos (persisted in user defaults).
struct WatchFolderSettings: Codable, Equatable {
    var folderPath: String?
    /// Where bundles go; nil writes to "Material Lab Exports" inside the watched folder (never rescanned).
    var outputPath: String?
    /// A saved recipe, or nil for the default flat recipe.
    var recipeID: UUID?
    var formats: [String] = []
    var paused = false
    /// Files already handled (or present when the folder was chosen), by name, with their modification time.
    var seen: [String: Double] = [:]

    static let defaultsKey = "materialLab.watchFolder"
    static let outputFolderName = "Material Lab Exports"

    static func load() -> WatchFolderSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(WatchFolderSettings.self, from: data) else { return WatchFolderSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    var outputURL: URL? {
        if let outputPath { return URL(fileURLWithPath: outputPath, isDirectory: true) }
        return folderURL?.appendingPathComponent(Self.outputFolderName, isDirectory: true)
    }
}

/// Watches one folder for new photos with a vnode dispatch source plus a slow rescan, and reports each photo once
/// its size has stopped changing (so files still being copied are not read half-written).
@MainActor
@Observable
final class WatchFolderService {
    enum State: Equatable { case off, watching, paused, missing }

    private(set) var state: State = .off
    /// When the folder was last scanned, for the status line.
    private(set) var lastScan: Date?
    /// Called with photos that are new and complete.
    @ObservationIgnored var onNewFiles: (([URL]) -> Void)?
    /// Asked whether a file was already handled.
    @ObservationIgnored var isSeen: ((String, Double) -> Bool)?

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var pendingSizes: [String: Int] = [:]
    @ObservationIgnored private var rescanTask: Task<Void, Never>?

    func start(_ folder: URL, paused: Bool) {
        stop()
        self.folder = folder
        guard FileManager.default.fileExists(atPath: folder.path) else {
            state = .missing
            return
        }
        state = paused ? .paused : .watching
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .rename, .delete, .extend],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.folderChanged() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        // A slow rescan catches events the vnode source coalesces and finishes files that were still copying.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scan()
    }

    func setPaused(_ paused: Bool) {
        guard state == .watching || state == .paused else { return }
        state = paused ? .paused : .watching
        if !paused {
            scan()
            folderChanged()
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
        rescanTask?.cancel()
        pendingSizes = [:]
        folder = nil
        state = .off
    }

    /// Photos currently in the folder with their modification times (top level only, hidden files skipped).
    static func photos(in folder: URL) -> [(url: URL, modified: Double, size: Int)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
            return (url, values.contentModificationDate?.timeIntervalSince1970 ?? 0, values.fileSize ?? 0)
        }
    }

    private func folderChanged() {
        // Check soon, then again shortly after, so a copy that just finished is picked up quickly.
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            for delay in [800, 1700] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    func scan() {
        guard let folder else { return }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            state = .missing
            return
        }
        if state == .missing { state = .watching }
        lastScan = Date()
        guard state == .watching else { return }
        var ready: [URL] = []
        var sizes: [String: Int] = [:]
        for photo in Self.photos(in: folder) {
            let name = photo.url.lastPathComponent
            if isSeen?(name, photo.modified) == true { continue }
            // Ready once two scans see the same non-zero size.
            if photo.size > 0, pendingSizes[name] == photo.size {
                ready.append(photo.url)
            } else {
                sizes[name] = photo.size
            }
        }
        pendingSizes = sizes
        if !ready.isEmpty { onNewFiles?(ready) }
    }
}
