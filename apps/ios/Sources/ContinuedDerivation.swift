import BackgroundTasks
import Foundation

/// Keeps a long full-resolution derivation running if the user leaves the app (iOS continued processing): the system
/// shows its progress in a Live Activity and may expire it, which cancels the derivation. One derivation runs at a
/// time, so a single launch handler, registered for the wildcard identifier on first use, serves every request.
final class ContinuedDerivation: @unchecked Sendable {
    private static let lock = NSLock()
    private static var registered = false
    private static var current: ContinuedDerivation?
    private static var prefix: String { (Bundle.main.bundleIdentifier ?? "io.materiallab.capture") + ".derive" }

    private let identifier: String
    private let onExpire: @Sendable () -> Void
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var fraction = 0.0
    private var outcome: Bool?

    private init(identifier: String, onExpire: @escaping @Sendable () -> Void) {
        self.identifier = identifier
        self.onExpire = onExpire
    }

    /// Asks the system to keep the derivation alive in the background. Returns nil when it declines (or on the
    /// simulator, which has no continued-processing support); the derivation then simply runs in the foreground.
    static func begin(title: String, subtitle: String, onExpire: @escaping @Sendable () -> Void) -> ContinuedDerivation? {
        let ready = lock.withLock { () -> Bool in
            if !registered {
                registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + ".*", using: nil) { task in
                    guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                    let session = lock.withLock { current }
                    guard let session, session.identifier == task.identifier else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    session.attach(task)
                }
            }
            return registered
        }
        guard ready else { return nil }
        let session = ContinuedDerivation(identifier: "\(prefix).\(UUID().uuidString)", onExpire: onExpire)
        let request = BGContinuedProcessingTaskRequest(identifier: session.identifier, title: title, subtitle: subtitle)
        // Run now or not at all: a derivation queued behind other work would finish in the foreground first.
        request.strategy = .fail
        lock.withLock { current = session }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            lock.withLock { if current === session { current = nil } }
            return nil
        }
        return session
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        task.expirationHandler = { [onExpire] in onExpire() }
        task.progress.totalUnitCount = 1000
        let finished = lock.withLock { () -> Bool? in
            self.task = task
            task.progress.completedUnitCount = Int64(fraction * 1000)
            return outcome
        }
        if let finished { task.setTaskCompleted(success: finished) }
    }

    /// Derivation progress in [0, 1], mirrored into the system's progress UI.
    func update(_ value: Double) {
        lock.withLock {
            fraction = value
            task?.progress.completedUnitCount = Int64(min(1, max(0, value)) * 1000)
        }
    }

    func finish(success: Bool) {
        let task = lock.withLock { () -> BGContinuedProcessingTask? in
            outcome = success
            return self.task
        }
        if let task {
            task.setTaskCompleted(success: success)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        Self.lock.withLock { if Self.current === self { Self.current = nil } }
    }
}
