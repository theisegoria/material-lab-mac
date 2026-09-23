import AppKit
import SwiftUI

struct PairingView: View {
    @Bindable var store: MaterialLabStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Device Link").font(.largeTitle.bold())
                Text("Transfer a capture directly from Material Capture on iPhone over local Bonjour and TLS.")
                    .foregroundStyle(.secondary)
                if let pending = store.link.pending {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Incoming capture needs approval", systemImage: "lock.shield")
                            .font(.headline)
                        Text(pending.inspection.semanticLabel).font(.title2.bold())
                        Text(pending.inspection.category).foregroundStyle(.secondary)
                        Text("The source image and optional maps passed size, hash, image, and metadata validation. Import will write to the local inbox.")
                            .font(.caption)
                        HStack {
                            Button("Approve and Import") { store.link.approvePending() }
                                .buttonStyle(.borderedProminent)
                            Button("Decline") { store.link.rejectPending() }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                HStack(spacing: 12) {
                    Button(store.link.isListening ? "New Pairing Code" : "Start Secure Link") {
                        if store.link.isListening { store.link.renewCode() }
                        else { store.link.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    if store.link.isListening {
                        Button("Stop Link") { store.link.stop() }
                    }
                    Button("Import Capture File…") { store.showBundleImporter = true }
                }
                Text(store.link.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let code = store.link.pairingJSON {
                    Button("Copy Pairing Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .help("Copy the exact QR payload for simulator or accessibility pairing.")
                }
                if let image = store.link.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 300, height: 300)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("One-time Material Lab pairing QR code")
                    if let expiry = store.link.expiresAt {
                        Text("Code expires \(expiry.formatted(date: .omitted, time: .shortened)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let fingerprint = store.link.leafSHA256 {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Mac TLS certificate SHA-256").font(.caption.bold())
                        Text(fingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Trust and fallback").font(.headline)
                Text("The iPhone pins this Mac certificate from the one-time QR. Every incoming capture requires approval on this Mac. Files or AirDrop use the same verified .pbrcapture format.")
                    .foregroundStyle(.secondary)
                Button("Reset Mac Device Trust…", role: .destructive) {
                    store.link.resetTrust()
                }
                .help("Creates a new Mac TLS identity; previously paired iPhones must pair again.")
            }
            .padding(24)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
