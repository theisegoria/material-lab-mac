import SwiftUI

/// Pairing and direct transfer to Material Lab on Mac. The link store lives at app level, so a scanned
/// single-use QR survives tab switches and capture edits.
struct MacLinkView: View {
    let store: CaptureStore
    @Bindable var link: MacLinkStore
    @State private var showScanner = false
    @State private var pastedCode = ""
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.pulse, isActive: link.isSending)
                    Text(headline)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(link.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            if let error = link.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let warning = link.warning {
                Section {
                    Label(warning, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("scan-mac-qr")
                HStack {
                    TextField("Or paste the pairing code", text: $pastedCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use") {
                        link.acceptPairing(pastedCode)
                        if link.pairing != nil { pastedCode = "" }
                    }
                    .buttonStyle(.glass)
                    .disabled(pastedCode.isEmpty)
                }
            } header: {
                Text("Pair")
            } footer: {
                Text("In Material Lab on Mac choose Pair iPhone. The QR code is single-use and expires after five minutes. This iPhone verifies the Mac's TLS certificate before sending anything.")
            }

            Section("Transfer") {
                LabeledContent("Material") {
                    Text(store.trimmedLabel.isEmpty ? "Unnamed" : store.trimmedLabel)
                }
                LabeledContent("Maps") {
                    if store.hasExportableMaps {
                        Label("\(String(store.resolution))² ready", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Derive full resolution first").foregroundStyle(.secondary)
                    }
                }
                if link.phase != .idle {
                    TransferSteps(phase: link.phase)
                }
                if link.isSending {
                    Button("Cancel Sending", systemImage: "xmark.circle", role: .cancel) { link.cancelSend() }
                } else {
                    Button {
                        link.send(from: store)
                    } label: {
                        Label("Send to Paired Mac", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(link.pairing == nil || !store.hasExportableMaps || store.trimmedLabel.isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            if let fingerprint = link.trustedFingerprint {
                Section {
                    LabeledContent("Certificate") {
                        Text(fingerprint.prefix(16) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Button("Forget Trusted Mac", role: .destructive) { confirmForget = true }
                } header: {
                    Text("Trusted Mac")
                }
            }
        }
        .navigationTitle("Mac Link")
        .confirmationDialog("Forget the trusted Mac?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) { link.forgetTrustedMac() }
        } message: {
            Text("You will need to scan a new pairing code before sending again.")
        }
        .sensoryFeedback(.success, trigger: link.phase) { _, new in new == .delivered }
        .sensoryFeedback(.error, trigger: link.phase) { _, new in new == .failed }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PairingScanner(onCode: { code in
                    link.acceptPairing(code)
                    showScanner = false
                }, onError: { error in
                    link.errorMessage = error
                    showScanner = false
                })
                .ignoresSafeArea()
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(.white, style: StrokeStyle(lineWidth: 3))
                        .frame(width: 240, height: 240)
                        .shadow(radius: 4)
                        .allowsHitTesting(false)
                }
                .navigationTitle("Scan Mac QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { showScanner = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    private var headline: String {
        switch link.phase {
        case .delivered: return "Delivered to Mac"
        case .failed: return "Transfer Interrupted"
        default:
            if link.isSending { return link.phase.title }
            if link.pairing != nil { return "Paired and Ready" }
            return link.trustedFingerprint == nil ? "Send Straight to Your Mac" : "Scan to Send Again"
        }
    }
}

private struct TransferSteps: View {
    let phase: LinkPhase
    private let steps: [(LinkPhase, String)] = [
        (.preparing, "Package"), (.connecting, "Connect"), (.uploading, "Upload"), (.awaitingApproval, "Approve")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let state = stepState(index)
                VStack(spacing: 4) {
                    Image(systemName: state == .done ? "checkmark.circle.fill" : state == .active ? "circle.dotted" : "circle")
                        .foregroundStyle(state == .done ? Color.green : state == .active ? Color.accentColor : Color.secondary)
                        .symbolEffect(.rotate, isActive: state == .active)
                    Text(step.1).font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transfer progress")
        .accessibilityValue(phase.title)
    }

    private enum StepState { case done, active, pending }

    private func stepState(_ index: Int) -> StepState {
        let order: [LinkPhase] = [.preparing, .connecting, .uploading, .awaitingApproval]
        if phase == .delivered { return .done }
        guard let current = order.firstIndex(of: phase) else { return .pending }
        return index < current ? .done : index == current ? .active : .pending
    }
}
