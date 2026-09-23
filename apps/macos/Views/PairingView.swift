import AppKit
import SwiftUI

struct PairingView: View {
    @Bindable var store: MaterialLabStore
    @State private var confirmReset = false

    private var link: LocalLinkService { store.link }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let pending = link.pending {
                    approvalCard(pending)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                HStack(alignment: .top, spacing: 28) {
                    qrPanel
                    VStack(alignment: .leading, spacing: 18) {
                        steps
                        statusRow
                        controls
                        if let fingerprint = link.leafSHA256 {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Mac certificate SHA-256")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(fingerprint)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trust").font(.headline)
                    Text("The iPhone pins this Mac's certificate from the one-time code. Every transfer still needs your approval here, and files sent through AirDrop use the same verified .pbrcapture format.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reset Device Trust…", role: .destructive) { confirmReset = true }
                        .disabled(link.isStarting)
                        .help("Creates a new Mac identity; paired iPhones must pair again.")
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: link.pending?.id)
        }
        .navigationTitle("Device Link")
        .navigationSubtitle(link.isListening ? "Listening on the local network" : "Stopped")
        .confirmationDialog("Reset device trust?", isPresented: $confirmReset) {
            Button("Reset Trust", role: .destructive) { link.resetTrust() }
        } message: {
            Text("A new Mac identity is created. Every paired iPhone must scan a new code.")
        }
    }

    private func approvalCard(_ pending: IncomingCapture) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Incoming capture").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(pending.inspection.semanticLabel).font(.title2.bold())
                Text("\(pending.inspection.category) · passed size, hash, image and privacy checks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Decline") { link.rejectPending() }
                .buttonStyle(.glass)
            Button("Approve & Import") { link.approvePending() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(20)
        .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.fill.quinary)
            if let image = link.qrImage {
                VStack(spacing: 10) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel("One-time Material Lab pairing code")
                    if let expiry = link.expiresAt {
                        Text("Expires at \(expiry.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: link.isStarting ? "hourglass" : "qrcode")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.tertiary)
                        .symbolEffect(.pulse, isActive: link.isStarting)
                    Text(link.isStarting ? "Preparing…" : "Start the link to show a pairing code")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .frame(width: 290, height: 300)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send captures from iPhone").font(.title3.weight(.semibold))
            step(1, "Start the secure link on this Mac.")
            step(2, "In Material Capture, choose Send to Mac and scan the code.")
            step(3, "Approve the capture here. It lands in the Camera Inbox.")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint.opacity(0.18)))
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        Label {
            Text(link.status).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Circle()
                .fill(link.isListening ? Color.green : (link.isStarting ? .yellow : .secondary))
                .frame(width: 8, height: 8)
        }
        .font(.callout)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if link.isListening {
                Button("New Code") { link.renewCode() }
                    .buttonStyle(.glassProminent)
                Button("Stop") { link.stop() }
                    .buttonStyle(.glass)
                if let code = link.pairingJSON {
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .buttonStyle(.glass)
                    .help("Copy the exact QR payload for simulator or accessibility pairing.")
                }
            } else {
                Button("Start Secure Link") { link.start() }
                    .buttonStyle(.glassProminent)
                    .disabled(link.isStarting)
            }
        }
        .controlSize(.large)
    }
}
