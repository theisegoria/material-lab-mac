import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Network
import Observation
import Security

struct IncomingCapture: Identifiable {
    let id = UUID()
    let inspection: CaptureInspection
    let envelope: Data
    let connection: NWConnection
}

@MainActor
@Observable
final class LocalLinkService {
    var status = "Secure local link is stopped."
    var isListening = false
    var leafSHA256: String?
    var qrImage: NSImage?
    var pairingJSON: String?
    var expiresAt: Date?
    var pending: IncomingCapture?
    var onImported: ((MaterialSource) -> Void)?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var identity: LocalLinkIdentity?
    @ObservationIgnored private var pairingToken: String?
    @ObservationIgnored private let queue = DispatchQueue(label: "io.materiallab.desktop.link")
    @ObservationIgnored private var connections: [ObjectIdentifier: NWConnection] = [:]
    @ObservationIgnored private var deadlines: [ObjectIdentifier: DispatchWorkItem] = [:]
    @ObservationIgnored private let instanceID = UUID().uuidString.lowercased()

    func start() {
        guard listener == nil else {
            renewCode()
            return
        }
        status = "Preparing the Mac TLS identity…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let identity = try LocalLinkIdentity.loadOrCreate()
                await self?.activate(identity: identity)
            } catch {
                await self?.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        deadlines.values.forEach { $0.cancel() }
        deadlines.removeAll()
        pending = nil
        isListening = false
        pairingToken = nil
        expiresAt = nil
        qrImage = nil
        pairingJSON = nil
        status = "Secure local link is stopped."
    }

    func resetTrust() {
        stop()
        do {
            try LocalLinkIdentity.reset()
            identity = nil
            leafSHA256 = nil
            status = "Mac identity rotated. Previous iPhone pins must be removed or paired again."
        } catch {
            fail(error.localizedDescription)
        }
    }

    func renewCode() {
        guard listener != nil, let identity else { return }
        do {
            let token = try LocalLinkIdentity.randomSecret()
            let expires = Date().addingTimeInterval(300)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let payload: [String: Any] = [
                "version": 1,
                "service": "_materiallab._tcp",
                "leafSHA256": identity.leafSHA256,
                "token": token,
                "expiresAt": formatter.string(from: expires)
            ]
            let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let filter = CIFilter.qrCodeGenerator()
            filter.message = json
            filter.correctionLevel = "M"
            guard let image = filter.outputImage?.transformed(
                by: CGAffineTransform(scaleX: 8, y: 8)
            ), let rendered = CIContext().createCGImage(image, from: image.extent) else {
                throw LocalLinkIdentityError.certificateGeneration("QR image creation failed")
            }
            pairingToken = token
            expiresAt = expires
            pairingJSON = String(data: json, encoding: .utf8)
            qrImage = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
            status = "Scan the code in Material Capture. This code expires in five minutes."
        } catch {
            fail(error.localizedDescription)
        }
    }

    func approvePending() {
        guard let incoming = pending else { return }
        pending = nil
        pairingToken = nil
        expiresAt = nil
        qrImage = nil
        pairingJSON = nil
        cancelDeadline(incoming.connection)
        status = "Importing approved capture…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let source = try MaterialBundle.importCapture(incoming.envelope)
                await self?.finishApproval(incoming, source: source)
            } catch {
                await self?.finishRejection(incoming, message: error.localizedDescription)
            }
        }
    }

    func rejectPending() {
        guard let incoming = pending else { return }
        pending = nil
        pairingToken = nil
        expiresAt = nil
        qrImage = nil
        pairingJSON = nil
        sendAcknowledgement(
            connection: incoming.connection,
            ok: false, captureID: nil, message: "Import declined on Mac"
        )
        status = "Capture declined. Generate a new code for another transfer."
    }

    private func activate(identity: LocalLinkIdentity) {
        guard listener == nil else { return }
        self.identity = identity
        leafSHA256 = identity.leafSHA256
        let tls = NWProtocolTLS.Options()
        guard let networkIdentity = sec_identity_create(identity.identity) else {
            fail("Could not bind the Mac TLS identity.")
            return
        }
        sec_protocol_options_set_local_identity(
            tls.securityProtocolOptions, networkIdentity
        )
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        do {
            let listener = try NWListener(using: parameters, on: .any)
            listener.service = NWListener.Service(
                name: "Material Lab", type: "_materiallab._tcp",
                txtRecord: NWTXTRecord(["version": "1", "instance": instanceID])
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.renewCode()
                    case .failed(let error):
                        self.fail("Local link failed: \(error.localizedDescription)")
                        self.stop()
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            fail("Could not advertise local link: \(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 2 else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        scheduleDeadline(connection, seconds: 30)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                Task { @MainActor in self?.readHeader(connection) }
            case .waiting, .failed, .cancelled:
                connection.cancel()
                Task { @MainActor in
                    self?.connections.removeValue(forKey: key)
                    self?.deadlines.removeValue(forKey: key)?.cancel()
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func readHeader(_ connection: NWConnection) {
        readExactly(connection, count: 4, state: LinkReceiveState()) { [weak self] result in
            switch result {
            case .failure:
                connection.cancel()
            case .success(let header):
                let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= MaterialBundle.maximumCaptureBytes else {
                    self?.sendAcknowledgement(
                        connection: connection, ok: false,
                        captureID: nil, message: "Transfer size exceeds 64 MiB"
                    )
                    return
                }
                self?.readExactly(
                    connection, count: Int(length), state: LinkReceiveState()
                ) { [weak self] body in
                    switch body {
                    case .failure: connection.cancel()
                    case .success(let data):
                        Task { @MainActor in self?.inspect(data, from: connection) }
                    }
                }
            }
        }
    }

    nonisolated private func readExactly(
        _ connection: NWConnection,
        count: Int,
        state: LinkReceiveState,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let remaining = count - state.bytes.count
        guard remaining > 0 else {
            completion(.success(state.bytes))
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: min(remaining, 64 * 1024)
        ) { [weak self] content, _, finished, error in
            if let error { completion(.failure(error)); return }
            guard let content, !content.isEmpty else {
                completion(.failure(LinkReceiveError.closed)); return
            }
            state.bytes.append(content)
            if state.bytes.count == count {
                completion(.success(state.bytes))
            } else if finished {
                completion(.failure(LinkReceiveError.closed))
            } else {
                self?.readExactly(
                    connection, count: count, state: state,
                    completion: completion
                )
            }
        }
    }

    private func inspect(_ data: Data, from connection: NWConnection) {
        guard pending == nil,
              let token = pairingToken,
              let expiry = expiresAt,
              Date() < expiry
        else {
            sendAcknowledgement(
                connection: connection, ok: false,
                captureID: nil, message: "Pairing code is invalid, expired, or busy"
            )
            return
        }
        scheduleDeadline(connection, seconds: 120)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let link = object["link"] as? [String: Any],
                      let received = link["token"] as? String,
                      secureTokenEqual(token, received)
                else { throw MaterialBundleError.invalidCapture("pairing token mismatch") }
                let inspection = try MaterialBundle.inspectCapture(data)
                await self?.presentValidated(
                    inspection, data: data, connection: connection, token: token
                )
            } catch {
                await self?.rejectInspection(
                    connection, message: error.localizedDescription
                )
            }
        }
    }

    private func presentValidated(
        _ inspection: CaptureInspection,
        data: Data,
        connection: NWConnection,
        token: String
    ) {
        guard connections[ObjectIdentifier(connection)] != nil,
              pending == nil,
              pairingToken == token,
              let expiry = expiresAt, Date() < expiry
        else {
            sendAcknowledgement(
                connection: connection, ok: false,
                captureID: nil, message: "Pairing code expired while validating"
            )
            return
        }
        pending = IncomingCapture(
            inspection: inspection, envelope: data, connection: connection
        )
        status = "Approve \(inspection.semanticLabel) before it enters the inbox."
    }

    private func rejectInspection(_ connection: NWConnection, message: String) {
        pairingToken = nil
        expiresAt = nil
        qrImage = nil
        pairingJSON = nil
        sendAcknowledgement(
            connection: connection, ok: false,
            captureID: nil, message: message
        )
    }

    private func scheduleDeadline(_ connection: NWConnection, seconds: TimeInterval) {
        let key = ObjectIdentifier(connection)
        deadlines[key]?.cancel()
        let item = DispatchWorkItem { [weak self, weak connection] in
            guard let connection else { return }
            Task { @MainActor in self?.expire(connection) }
        }
        deadlines[key] = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelDeadline(_ connection: NWConnection) {
        deadlines.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
    }

    private func expire(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard connections[key] != nil else { return }
        if pending?.connection === connection {
            pending = nil
            pairingToken = nil
            expiresAt = nil
            qrImage = nil
            pairingJSON = nil
        }
        connections.removeValue(forKey: key)
        cancelDeadline(connection)
        if case .ready = connection.state {
            sendAcknowledgement(
                connection: connection, ok: false,
                captureID: nil, message: "Transfer or approval timed out"
            )
            queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        } else {
            connection.cancel()
        }
        status = "Local transfer timed out. Generate a new pairing code."
    }

    private func finishApproval(
        _ incoming: IncomingCapture, source: MaterialSource
    ) {
        onImported?(source)
        sendAcknowledgement(
            connection: incoming.connection, ok: true,
            captureID: incoming.inspection.captureID.uuidString,
            message: nil
        )
        status = "Capture imported and verified. Generate a new code for another transfer."
    }

    private func finishRejection(
        _ incoming: IncomingCapture, message: String
    ) {
        sendAcknowledgement(
            connection: incoming.connection, ok: false,
            captureID: nil, message: message
        )
        status = "Capture import failed: \(message)"
    }

    private func sendAcknowledgement(
        connection: NWConnection,
        ok: Bool,
        captureID: String?,
        message: String?
    ) {
        cancelDeadline(connection)
        var reply: [String: Any] = ["ok": ok]
        if let captureID { reply["captureId"] = captureID }
        if let message { reply["error"] = String(message.prefix(240)) }
        guard let json = try? JSONSerialization.data(withJSONObject: reply),
              json.count <= Int(UInt32.max)
        else { connection.cancel(); return }
        var size = UInt32(json.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(json)
        connection.send(content: frame, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func fail(_ text: String) {
        status = text
        isListening = false
    }

}

private final class LinkReceiveState: @unchecked Sendable {
    var bytes = Data()
}

private enum LinkReceiveError: Error {
    case closed
}


private func secureTokenEqual(_ expected: String, _ actual: String) -> Bool {
    let lhs = Array(expected.utf8)
    let rhs = Array(actual.utf8)
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for i in lhs.indices { difference |= lhs[i] ^ rhs[i] }
    return difference == 0
}
