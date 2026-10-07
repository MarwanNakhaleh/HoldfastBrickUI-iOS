import SwiftUI

/// Manage blocklist subscriptions: see what's active, add by URL, remove.
struct BlocklistsView: View {
    @Bindable var model: AdBlockingModel
    @State private var showingAdd = false

    var body: some View {
        List {
            Section {
                ForEach(model.blocklists) { blocklist in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(blocklist.name).font(.subheadline.weight(.medium))
                            Spacer()
                            if !blocklist.enabled {
                                Text("Off").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(blocklist.url)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if blocklist.rulesCount > 0 {
                            Text("\(blocklist.rulesCount.formatted()) rules")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { indexSet in
                    let doomed = indexSet.map { model.blocklists[$0] }
                    Task { for blocklist in doomed { await model.removeBlocklist(blocklist) } }
                }
            } footer: {
                Text("Blocklists are curated catalogs of ad and tracker domains. More lists block more, but very aggressive lists can break some sites.")
            }

            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Blocklists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add blocklist", systemImage: "plus")
                }
                .accessibilityIdentifier("blocklists.addButton")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddBlocklistSheet(model: model)
        }
        .overlay {
            if model.isLoading && model.blocklists.isEmpty { ProgressView() }
        }
        .task { await model.loadBlocklists() }
        .refreshable { await model.loadBlocklists() }
    }
}

private struct AddBlocklistSheet: View {
    @Bindable var model: AdBlockingModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var isSaving = false

    private var urlIsValid: Bool {
        guard let parsed = URL(string: url) else { return false }
        return parsed.scheme == "https" && parsed.host() != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. OISD Basic)", text: $name)
                    TextField("https://…", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Paste the URL of a blocklist. Popular, well-maintained options: OISD, HaGeZi, AdGuard DNS filter.")
                }
            }
            .navigationTitle("Add Blocklist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        isSaving = true
                        Task {
                            let added = await model.addBlocklist(
                                name: name.isEmpty ? url : name, url: url
                            )
                            isSaving = false
                            if added { dismiss() }
                        }
                    }
                    .disabled(!urlIsValid || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
