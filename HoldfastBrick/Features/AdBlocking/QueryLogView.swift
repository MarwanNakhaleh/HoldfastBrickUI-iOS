import SwiftUI

/// Recent DNS activity. Blocked lookups are visually distinct, and any row can
/// be blocked/allowed with a swipe or long-press.
struct QueryLogView: View {
    private struct Confirmation: Identifiable {
        let message: String
        var id: String { message }
    }

    @Bindable var model: AdBlockingModel
    @State private var confirmation: Confirmation?

    var body: some View {
        List {
            if model.entries.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("DNS lookups from your network will appear here.")
                )
            }

            ForEach(model.entries) { entry in
                QueryLogRow(entry: entry)
                    .swipeActions(edge: .trailing) {
                        if entry.blocked {
                            Button {
                                apply(.allow, to: entry.domain)
                            } label: {
                                Label("Allow", systemImage: "checkmark.circle")
                            }
                            .tint(.green)
                        } else {
                            Button {
                                apply(.deny, to: entry.domain)
                            } label: {
                                Label("Block", systemImage: "hand.raised")
                            }
                            .tint(.red)
                        }
                    }
                    .contextMenu {
                        Button("Block \(entry.domain)") { apply(.deny, to: entry.domain) }
                        Button("Allow \(entry.domain)") { apply(.allow, to: entry.domain) }
                    }
            }
        }
        .navigationTitle("Recent Activity")
        .searchable(text: $model.searchText, prompt: "Filter by domain")
        .onSubmit(of: .search) { Task { await model.loadQueryLog() } }
        .onChange(of: model.searchText) { _, newValue in
            if newValue.isEmpty { Task { await model.loadQueryLog() } }
        }
        .overlay {
            if model.isLoading && model.entries.isEmpty { ProgressView() }
        }
        .task { await model.loadQueryLog() }
        .refreshable { await model.loadQueryLog() }
        .alert(item: $confirmation) { confirmation in
            Alert(title: Text(confirmation.message))
        }
    }

    private func apply(_ action: DomainRuleAction, to domain: String) {
        Task {
            await model.setRule(domain: domain, action: action)
            confirmation = Confirmation(
                message: action == .deny ? "\(domain) is now blocked" : "\(domain) is now allowed"
            )
            await model.loadQueryLog()
        }
    }
}

private struct QueryLogRow: View {
    let entry: QueryLogEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.blocked ? "hand.raised.fill" : "checkmark.circle")
                .foregroundStyle(entry.blocked ? Color.red : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.domain)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(entry.client)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.blocked {
                Text("Blocked")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
            }
        }
    }
}
