import SwiftUI

/// Per-source status of the current batch, with retry for failures and a JSON report.
struct BatchQueueView: View {
    @Bindable var store: MaterialLabStore

    var body: some View {
        VStack(spacing: 0) {
            if store.batchItems.isEmpty {
                ContentUnavailableView("No Batch Yet", systemImage: "square.stack.3d.down.right",
                                       description: Text("Choose Material › Batch Export Eligible Sources to queue every reviewed source with the current recipe."))
            } else {
                Table(store.batchItems) {
                    TableColumn("Source") { item in
                        Text(item.source.displayName).lineLimit(1)
                    }
                    TableColumn("Status") { item in status(item.state) }
                        .width(min: 140, ideal: 220)
                    TableColumn("Time") { item in
                        Text(item.duration.map { String(format: "%.1f s", $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(70)
                    TableColumn("") { item in
                        if let bundle = item.bundle {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([bundle])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Show the bundle in Finder")
                        }
                    }
                    .width(28)
                }
            }
            Divider()
            HStack {
                if store.isBatching {
                    ProgressView(value: Double(store.batchProgress)).frame(width: 160)
                    Text(store.status).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(store.batchDoneCount) exported · \(store.batchFailedCount) failed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isBatching {
                    Button("Cancel") { store.cancel() }
                } else {
                    Button("Retry Failed") { store.retryFailedBatchItems() }
                        .disabled(store.batchFailedCount == 0 &&
                                  !store.batchItems.contains { $0.state == .cancelled })
                    Button("Save Report…") { store.saveBatchReport() }
                        .disabled(store.batchItems.isEmpty)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 320)
    }

    @ViewBuilder
    private func status(_ state: MaterialLabStore.BatchItem.State) -> some View {
        switch state {
        case .queued: Label("Queued", systemImage: "clock").foregroundStyle(.secondary)
        case .running: Label("Deriving…", systemImage: "wand.and.sparkles").foregroundStyle(.tint)
        case .done: Label("Exported", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange).lineLimit(2).help(message)
        case .cancelled: Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}
