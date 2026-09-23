import SwiftUI

struct SourceSidebar: View {
    @Bindable var store: MaterialLabStore
    @Binding var selection: SidebarDestination

    var body: some View {
        List(selection: $selection) {
            Section("Workspace") {
                Label("Camera Inbox", systemImage: "camera")
                    .badge(store.inboxCount)
                    .tag(SidebarDestination.inbox)
                Label("Device Link", systemImage: "network")
                    .tag(SidebarDestination.link)
            }
            Section("Sources") {
                ForEach(store.filteredSources) { source in
                    HStack(spacing: 9) {
                        Image(systemName: source.origin.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 17)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName).lineLimit(1)
                            Text(source.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(SidebarDestination.source(source.id))
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $store.searchText, prompt: "Search materials")
        .accessibilityLabel("Material sources")
        .onChange(of: selection) { _, next in
            if case .source(let id) = next { store.selectSource(id) }
        }
    }
}
