import SwiftUI

/// Ad Blocking home: the big on/off switch, today's numbers, and doors into
/// Recent Activity and Blocklists.
struct AdBlockingView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: AdBlockingModel?
    @State private var isToggling = false

    private var service: ServiceStatus? {
        appModel.overview?.services.first { $0.id == "adguard" }
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: toggleBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Block ads & trackers").font(.headline)
                        Text("Applies to every device on your network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isToggling)
                .accessibilityIdentifier("adblocking.toggle")
            }

            if let stats = model?.stats {
                Section("Today") {
                    statRow("Lookups handled", stats.totalQueries.formatted())
                    statRow("Ads & trackers blocked", stats.blocked.formatted())
                    statRow("Blocked", stats.blockedPercent.formatted(.number.precision(.fractionLength(1))) + "%")
                }
            }

            Section {
                NavigationLink {
                    if let model { QueryLogView(model: model) }
                } label: {
                    Label("Recent activity", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("adblocking.queryLogLink")

                NavigationLink {
                    if let model { BlocklistsView(model: model) }
                } label: {
                    Label("Blocklists", systemImage: "shield.lefthalf.filled")
                }
                .accessibilityIdentifier("adblocking.blocklistsLink")

                NavigationLink {
                    WholeHomeView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Whole-home protection")
                            Text(model?.wholeHomeEnabled == true
                                 ? "On — brick manages your network" : "Set up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "house.fill")
                    }
                }
                .accessibilityIdentifier("adblocking.wholeHomeLink")
            }

            if let message = model?.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Ad Blocking")
        .task {
            if model == nil { model = AdBlockingModel(api: appModel.api) }
            await model?.loadStats()
            await model?.loadWholeHomeStatus()
        }
        .refreshable {
            await model?.loadStats()
            await model?.loadWholeHomeStatus()
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { service?.running ?? false },
            set: { enabled in
                isToggling = true
                Task {
                    await appModel.perform { try await $0.setAdBlocking(enabled: enabled) }
                    isToggling = false
                }
            }
        )
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
