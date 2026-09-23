import SwiftUI

struct MacLinkSection: View {
    let store: CaptureStore
    @State private var link = MacLinkStore()
    @State private var showScanner = false
    @State private var pastedCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Direct Mac link", systemImage: "laptopcomputer.and.iphone")
                .font(.headline)
            Text("Open Pair iPhone in Material Lab on Mac, then scan its one-time QR code. The iPhone verifies the Mac TLS certificate before sending.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Scan Mac QR") { showScanner = true }
                    .buttonStyle(.bordered)
                if let fingerprint = link.trustedFingerprint {
                    Text("Trusted: \(fingerprint.prefix(12))…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Or paste pairing QR JSON", text: $pastedCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use") { link.acceptPairing(pastedCode) }
                    .disabled(pastedCode.isEmpty)
            }
            if link.pairing != nil {
                Button {
                    Task { await link.send(from: store) }
                } label: {
                    if link.isSending {
                        HStack { ProgressView(); Text("Sending securely…") }
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Send to paired Mac", systemImage: "arrow.up.right")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(link.isSending || store.derived == nil)
                .accessibilityIdentifier("send-to-mac")
            }
            Text(link.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = link.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if link.trustedFingerprint != nil {
                Button("Forget trusted Mac", role: .destructive) { link.forgetTrustedMac() }
                    .font(.caption)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PairingScanner(onCode: { code in
                    link.acceptPairing(code)
                    showScanner = false
                }, onError: { error in
                    link.errorMessage = error
                    showScanner = false
                })
                .overlay(alignment: .center) {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.yellow, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                        .padding(50)
                        .allowsHitTesting(false)
                }
                .navigationTitle("Scan Mac pairing QR")
                .toolbar { Button("Done") { showScanner = false } }
            }
        }
    }
}
