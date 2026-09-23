import CryptoKit
import Foundation
import Network
import Observation
import Security

struct PairingCode: Decodable {
    let version: Int
    let service: String
    let leafSHA256: String
    let token: String
    let expiresAt: String

    init(json: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        guard version == 1, service == "_materiallab._tcp",
              leafSHA256.count == 64,
              leafSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let tokenData = Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+")
                                          .replacingOccurrences(of: "_", with: "/")
                                          .padding(toLength: ((token.count + 3) / 4) * 4,
                                                   withPad: "=", startingAt: 0)),
              tokenData.count == 32,
              let expiration = ISO8601DateFormatter().date(from: expiresAt),
              expiration > Date() else { throw LinkError.invalidPairingCode }
    }

    var expiration: Date? { ISO8601DateFormatter().date(from: expiresAt) }
}

enum LinkError: LocalizedError {
    case invalidPairingCode
    case differentTrustedMac
    case noMacFound
    case connectionFailed(String)
    case rejected(String)
    case invalidAcknowledgement
    case transferTooLarge
    case timedOut(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidPairingCode: "The Mac pairing code is invalid or expired. Refresh it on the Mac and scan again."
        case .differentTrustedMac: "This QR code belongs to a different Mac. Forget the current trusted Mac first."
        case .noMacFound: "No Material Lab Mac was found on this local network."
        case .connectionFailed(let detail): "Secure connection failed: \(detail)"
        case .rejected(let detail): "The Mac declined the capture: \(detail)"
        case .invalidAcknowledgement: "The Mac returned an invalid acknowledgement."
        case .transferTooLarge: "The capture exceeds the 64 MiB direct-link limit."
        case .timedOut(let phase): "Timed out \(phase)."
        case .cancelled: "Sending was cancelled."
        }
    }
}

private enum TrustedMacKeychain {
    private static let service = "io.materiallab.capture.trusted-mac"
    private static let account = "tls-leaf-sha256"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ fingerprint: String) throws {
        delete()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecValueData as String: Data(fingerprint.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw LinkError.connectionFailed("Could not save trusted Mac identity")
        }
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

enum LinkPhase: Equatable, Sendable {
    case idle, preparing, connecting, uploading, awaitingApproval, delivered, failed

    var title: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Packaging capture…"
        case .connecting: "Connecting securely…"
        case .uploading: "Uploading…"
        case .awaitingApproval: "Waiting for approval on Mac…"
        case .delivered: "Delivered"
        case .failed: "Not delivered"
        }
    }
    var isActive: Bool { [.preparing, .connecting, .uploading, .awaitingApproval].contains(self) }
}

@MainActor
@Observable
final class MacLinkStore {
    var pairing: PairingCode?
    var trustedFingerprint: String?
    var status = "Scan the QR code shown by Material Lab on Mac."
    var phase: LinkPhase = .idle
    var errorMessage: String?
    /// Non-fatal note, e.g. a delivered transfer whose Mac identity could not be remembered.
    var warning: String?
    var isSending: Bool { phase.isActive }
    private var sendTask: Task<Void, Never>?

    init() { trustedFingerprint = TrustedMacKeychain.load() }

    func acceptPairing(_ text: String) {
        do {
            let code = try PairingCode(json: text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let trustedFingerprint, trustedFingerprint != code.leafSHA256 {
                throw LinkError.differentTrustedMac
            }
            pairing = code
            phase = .idle
            status = "Mac identity pinned. Ready to send this capture."
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func send(from store: CaptureStore) {
        guard !isSending else { return }
        sendTask = Task { await performSend(from: store) }
    }

    func cancelSend() { sendTask?.cancel() }

    private func performSend(from store: CaptureStore) async {
        guard let pairing, (pairing.expiration ?? .distantPast) > Date() else {
            errorMessage = LinkError.invalidPairingCode.localizedDescription
            return
        }
        phase = .preparing
        status = LinkPhase.preparing.title
        errorMessage = nil
        warning = nil
        // A fresh ID per send; the acknowledgement must name exactly this capture.
        let expectedID = UUID()
        do {
            let envelope = try await store.makeBundle(linkToken: pairing.token, captureId: expectedID)
            try Task.checkCancellation()
            let acceptedID = try await MaterialLinkClient().send(envelope: envelope, pairing: pairing,
                                                                  captureId: expectedID) { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.phase.isActive else { return }
                    self.phase = phase
                    self.status = phase.title
                }
            }
            guard acceptedID == expectedID else { throw LinkError.invalidAcknowledgement }
            self.pairing = nil // One-time token: a fresh QR is required for another transfer.
            phase = .delivered
            status = "Accepted by Material Lab on Mac."
            do {
                try TrustedMacKeychain.save(pairing.leafSHA256)
                trustedFingerprint = pairing.leafSHA256
            } catch {
                warning = "Delivered, but this iPhone could not remember the Mac. You will be asked to scan again next time."
            }
        } catch is CancellationError {
            phase = .idle
            status = "Sending cancelled. The capture remains on this iPhone."
        } catch LinkError.cancelled {
            phase = .idle
            status = "Sending cancelled. The capture remains on this iPhone."
        } catch {
            phase = .failed
            status = "Transfer did not complete. The capture remains on this iPhone."
            errorMessage = error.localizedDescription
        }
        sendTask = nil
    }

    func forgetTrustedMac() {
        TrustedMacKeychain.delete()
        trustedFingerprint = nil
        pairing = nil
        phase = .idle
        status = "Trusted Mac removed. Scan a pairing QR to link again."
    }
}

private final class CompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let receiver = continuation
        continuation = nil
        lock.unlock()
        guard let receiver else { return false }
        receiver.resume(with: result)
        return true
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Cancels every registered network object when the owning task is cancelled.
private final class CancellationScope: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    func register(_ handler: @escaping () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if cancelled { return true }
            handlers.append(handler)
            return false
        }
        if runNow { handler() }
    }

    func cancel() {
        let pending = lock.withLock { () -> [() -> Void] in
            cancelled = true
            defer { handlers.removeAll() }
            return handlers
        }
        pending.forEach { $0() }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
}

final class MaterialLinkClient: @unchecked Sendable {
    /// TLS handshake budget.
    static let handshakeTimeout: TimeInterval = 15
    /// Upload budget; the Mac allows 30 s from accept to a fully received frame.
    static let uploadTimeout: TimeInterval = 45
    /// After upload the Mac validates and waits up to 120 s for the user; allow margin for its reply.
    static let approvalTimeout: TimeInterval = 160

    private let queue = DispatchQueue(label: "io.materiallab.capture.link", qos: .userInitiated)
    private let scope = CancellationScope()

    func send(envelope: Data, pairing: PairingCode, captureId: UUID? = nil,
              onPhase: @escaping @Sendable (LinkPhase) -> Void = { _ in }) async throws -> UUID {
        guard envelope.count > 0 && envelope.count <= 64 * 1024 * 1024 else { throw LinkError.transferTooLarge }
        return try await withTaskCancellationHandler {
            onPhase(.connecting)
            let endpoints = try await discover()
            var lastError: Error = LinkError.noMacFound
            for endpoint in endpoints {
                if scope.isCancelled { throw LinkError.cancelled }
                do {
                    return try await connectAndSend(endpoint: endpoint, envelope: envelope, pairing: pairing,
                                                    captureId: captureId, onPhase: onPhase)
                } catch LinkError.cancelled {
                    throw LinkError.cancelled
                } catch {
                    lastError = error
                }
            }
            throw lastError
        } onCancel: {
            scope.cancel()
        }
    }

    private func discover() async throws -> [NWEndpoint] {
        try await withCheckedThrowingContinuation { continuation in
            // The pairing QR carries no instance ID, so every advertised Mac is tried; the TLS leaf
            // pin rejects any Mac other than the one that showed the QR before capture bytes are sent.
            let browser = NWBrowser(for: .bonjour(type: "_materiallab._tcp", domain: nil), using: .tcp)
            let gate = CompletionGate(continuation)
            browser.browseResultsChangedHandler = { results, _ in
                let endpoints = results.map(\.endpoint)
                if !endpoints.isEmpty {
                    browser.cancel()
                    gate.finish(.success(endpoints))
                }
            }
            browser.stateUpdateHandler = { [scope] state in
                switch state {
                case .failed(let error):
                    browser.cancel()
                    gate.finish(.failure(LinkError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    gate.finish(.failure(scope.isCancelled ? LinkError.cancelled : LinkError.noMacFound))
                default: break
                }
            }
            scope.register { browser.cancel() }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) {
                browser.cancel()
                gate.finish(.failure(LinkError.noMacFound))
            }
        }
    }

    private func connectAndSend(endpoint: NWEndpoint, envelope: Data, pairing: PairingCode, captureId: UUID?,
                                onPhase: @escaping @Sendable (LinkPhase) -> Void) async throws -> UUID {
        let tls = NWProtocolTLS.Options()
        let expected = pairing.leafSHA256
        let pinState = Flag()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, peerTrust, complete in
            let trust = sec_trust_copy_ref(peerTrust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let certificate = chain.first else {
                complete(false)
                return
            }
            let DER = SecCertificateCopyData(certificate) as Data
            let actual = SHA256.hash(data: DER).map { String(format: "%02x", $0) }.joined()
            let matched = actual == expected
            if !matched { pinState.set() }
            complete(matched)
        }, queue)
        let connection = NWConnection(to: endpoint,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        scope.register { connection.cancel() }
        defer { connection.cancel() }
        try await ready(connection, pinState: pinState)

        onPhase(.uploading)
        // Send the 4-byte length and the payload as two writes: no 64 MiB framed copy.
        var size = UInt32(envelope.count).bigEndian
        let header = withUnsafeBytes(of: &size) { Data($0) }
        try await withDeadline(Self.uploadTimeout, connection: connection, phase: "while uploading to the Mac") {
            connection.send(content: header, completion: .contentProcessed { _ in })
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: envelope, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: LinkError.connectionFailed(error.localizedDescription)) }
                    else { continuation.resume() }
                })
            }
        }

        onPhase(.awaitingApproval)
        let body = try await withDeadline(Self.approvalTimeout, connection: connection,
                                          phase: "waiting for approval on the Mac") {
            let header = try await self.receiveExactly(4, from: connection)
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0 && length <= 4096 else { throw LinkError.invalidAcknowledgement }
            return try await self.receiveExactly(Int(length), from: connection)
        }
        struct Ack: Decodable { let ok: Bool; let captureId: UUID?; let error: String? }
        let ack = try JSONDecoder().decode(Ack.self, from: body)
        if !ack.ok {
            let reason = ack.error ?? "No reason supplied"
            // The Mac already holds this exact capture (e.g. an earlier attempt's reply was lost).
            if Self.isDuplicate(reason), let id = captureId ?? Self.captureID(in: envelope) { return id }
            throw LinkError.rejected(reason)
        }
        guard let id = ack.captureId else { throw LinkError.invalidAcknowledgement }
        return id
    }

    static func isDuplicate(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        return lowered.contains("duplicate") || lowered.contains("already in the inbox")
    }

    private static func captureID(in envelope: Data) -> UUID? {
        struct Envelope: Decodable { let captureId: UUID }
        return try? JSONDecoder().decode(Envelope.self, from: envelope).captureId
    }

    /// Runs `body`, cancelling the connection if it exceeds `seconds`, and maps the outcome to a clear error.
    private func withDeadline<T>(_ seconds: TimeInterval, connection: NWConnection, phase: String,
                                 _ body: () async throws -> T) async throws -> T {
        let fired = Flag()
        let timer = DispatchWorkItem {
            fired.set()
            connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: timer)
        defer { timer.cancel() }
        do {
            return try await body()
        } catch {
            if scope.isCancelled { throw LinkError.cancelled }
            if fired.isSet { throw LinkError.timedOut(phase) }
            throw error
        }
    }

    private func ready(_ connection: NWConnection, pinState: Flag) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = CompletionGate(continuation)
            let scope = self.scope
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case .failed(let error), .waiting(let error):
                    let reason = pinState.isSet ? "Mac TLS identity does not match the scanned QR" : error.localizedDescription
                    gate.finish(.failure(LinkError.connectionFailed(reason)))
                    connection.cancel()
                case .cancelled:
                    if scope.isCancelled { gate.finish(.failure(LinkError.cancelled)); return }
                    let reason = pinState.isSet ? "Mac TLS identity does not match the scanned QR" : "Connection cancelled"
                    gate.finish(.failure(LinkError.connectionFailed(reason)))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) {
                let reason = pinState.isSet ? "Mac TLS identity does not match the scanned QR" : "TLS handshake timed out"
                if gate.finish(.failure(LinkError.connectionFailed(reason))) {
                    connection.cancel()
                }
            }
        }
    }

    private func receiveExactly(_ size: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < size {
            let remaining = size - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                    if let error { continuation.resume(throwing: LinkError.connectionFailed(error.localizedDescription)) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: LinkError.invalidAcknowledgement) }
                }
            }
            result.append(chunk)
        }
        return result
    }
}
