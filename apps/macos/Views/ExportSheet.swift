import SwiftUI

/// Chooses the engine and interchange formats written beside the .pbrmaterial bundle, then exports.
struct ExportSheet: View {
    @Bindable var store: MaterialLabStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Material")
                    .font(.title2.weight(.semibold))
                Text("The .pbrmaterial bundle (every map plus its manifest) is always written. Choose formats to add beside it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Form {
                ForEach(ExportTarget.Group.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(ExportTarget.all.filter { $0.group == group }) { target in
                            Toggle(isOn: binding(for: target)) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.title)
                                        Text(target.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: target.symbol)
                                }
                            }
                            .accessibilityIdentifier("export-target-\(target.id)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button("Select None") { store.exportTargets = [] }
                    .disabled(store.exportTargets.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(exportTitle) {
                    dismiss()
                    // Let the sheet close before the folder panel opens.
                    Task { @MainActor in store.exportSelected() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!store.canExport)
            }
            .padding(20)
        }
        .frame(width: 520, height: 620)
    }

    private var exportTitle: String {
        let count = store.exportTargets.count
        return count == 0 ? String(localized: "Export Bundle…") : String(localized: "Export Bundle + \(count)…")
    }

    private func binding(for target: ExportTarget) -> Binding<Bool> {
        Binding(
            get: { store.exportTargets.contains(target.id) },
            set: { on in
                if on { store.exportTargets.insert(target.id) } else { store.exportTargets.remove(target.id) }
            }
        )
    }
}
