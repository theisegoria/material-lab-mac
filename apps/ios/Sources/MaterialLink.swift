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

    var errorDescription: String? {
        switch self {
        case .invalidPairingCode: "The Mac pairing code is invalid or expired. Refresh it on the Mac and scan again."
        case .differentTrustedMac: "This QR code belongs to a different Mac. Forget the current trusted Mac first."
        case .noMacFound: "No Material Lab Mac was found on this local network."
        case .connectionFailed(let detail): "Secure connection failed: \(detail)"
        case .rejected(let detail): "The Mac declined the capture: \(detail)"
        case .invalidAcknowledgement: "The Mac returned an invalid acknowledgement."
        case .transferTooLarge: "The capture exceeds the 64 MiB direct-link limit."
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

@MainActor
@Observable
final class MacLinkStore {
    var pairing: PairingCode?
    var trustedFingerprint: String?
    var status = "Scan the QR code shown by Material Lab on Mac."
    var isSending = false
    var errorMessage: String?

    init() { trustedFingerprint = TrustedMacKeychain.load() }

    func acceptPairing(_ text: String) {
        do {
            let code = try PairingCode(json: text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let trustedFingerprint, trustedFingerprint != code.leafSHA256 {
                throw LinkError.differentTrustedMac
            }
            pairing = code
            status = "Mac identity pinned. Ready to send this capture."
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func send(from store: CaptureStore) async {
        guard let pairing else { errorMessage = LinkError.invalidPairingCode.localizedDescription; return }
        guard (pairing.expiration ?? .distantPast) > Date() else {
            errorMessage = LinkError.invalidPairingCode.localizedDescription
            return
        }
        isSending = true
        status = "Connecting securely and waiting for Mac approval…"
        do {
            let envelope = try store.bundle(linkToken: pairing.token)
            let acceptedId = try await MaterialLinkClient().send(envelope: envelope, pairing: pairing)
            guard acceptedId == store.source?.id else { throw LinkError.invalidAcknowledgement }
            try TrustedMacKeychain.save(pairing.leafSHA256)
            trustedFingerprint = pairing.leafSHA256
            self.pairing = nil // One-time token: a fresh QR is required for another transfer.
            status = "Transfer accepted by Material Lab on Mac."
            errorMessage = nil
        } catch {
            status = "Transfer did not complete. The capture remains on this iPhone."
            errorMessage = error.localizedDescription
        }
        isSending = false
    }

    func forgetTrustedMac() {
        TrustedMacKeychain.delete()
        trustedFingerprint = nil
        pairing = nil
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

private final class LeafPinState: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false

    func markRejected() {
        lock.lock()
        rejected = true
        lock.unlock()
    }

    var didReject: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }
}

final class MaterialLinkClient {
    private let queue = DispatchQueue(label: "io.materiallab.capture.link", qos: .userInitiated)

    func send(envelope: Data, pairing: PairingCode) async throws -> UUID {
        guard envelope.count > 0 && envelope.count <= 64 * 1024 * 1024 else { throw LinkError.transferTooLarge }
        let endpoints = try await discover()
        var lastError: Error = LinkError.noMacFound
        for endpoint in endpoints {
            do { return try await connectAndSend(endpoint: endpoint, envelope: envelope, pairing: pairing) }
            catch { lastError = error }
        }
        throw lastError
    }

    private func discover() async throws -> [NWEndpoint] {
        try await withCheckedThrowingContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: "_materiallab._tcp", domain: nil), using: .tcp)
            let gate = CompletionGate(continuation)
            browser.browseResultsChangedHandler = { results, _ in
                let endpoints = results.map(\.endpoint)
                if !endpoints.isEmpty {
                    browser.cancel()
                    gate.finish(.success(endpoints))
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    browser.cancel()
                    gate.finish(.failure(LinkError.connectionFailed(error.localizedDescription)))
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) {
                browser.cancel()
                gate.finish(.failure(LinkError.noMacFound))
            }
        }
    }

    private func connectAndSend(endpoint: NWEndpoint, envelope: Data, pairing: PairingCode) async throws -> UUID {
        let tls = NWProtocolTLS.Options()
        let expected = pairing.leafSHA256
        let pinState = LeafPinState()
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
            if !matched { pinState.markRejected() }
            complete(matched)
        }, queue)
        let connection = NWConnection(to: endpoint,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        defer { connection.cancel() }
        try await ready(connection, pinState: pinState)
        let deadline = Task {
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { deadline.cancel() }
        var size = UInt32(envelope.count).bigEndian
        var frame = Data(bytes: &size, count: 4)
        frame.append(envelope)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: LinkError.connectionFailed(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
        let header = try await receiveExactly(4, from: connection)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 && length <= 4096 else { throw LinkError.invalidAcknowledgement }
        let body = try await receiveExactly(Int(length), from: connection)
        struct Ack: Decodable { let ok: Bool; let captureId: UUID?; let error: String? }
        let ack = try JSONDecoder().decode(Ack.self, from: body)
        if !ack.ok { throw LinkError.rejected(ack.error ?? "No reason supplied") }
        guard let id = ack.captureId else { throw LinkError.invalidAcknowledgement }
        return id
    }

    private func ready(_ connection: NWConnection, pinState: LeafPinState) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = CompletionGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case .failed(let error), .waiting(let error):
                    let reason = pinState.didReject ? "Mac TLS identity does not match the scanned QR" : error.localizedDescription
                    gate.finish(.failure(LinkError.connectionFailed(reason)))
                    connection.cancel()
                case .cancelled:
                    let reason = pinState.didReject ? "Mac TLS identity does not match the scanned QR" : "Connection cancelled"
                    gate.finish(.failure(LinkError.connectionFailed(reason)))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                let reason = pinState.didReject ? "Mac TLS identity does not match the scanned QR" : "TLS handshake timed out"
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
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error { continuation.resume(throwing: LinkError.connectionFailed(error.localizedDescription)) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: LinkError.invalidAcknowledgement) }
                    else { continuation.resume(throwing: LinkError.invalidAcknowledgement) }
                }
            }
            result.append(chunk)
        }
        return result
    }
}
