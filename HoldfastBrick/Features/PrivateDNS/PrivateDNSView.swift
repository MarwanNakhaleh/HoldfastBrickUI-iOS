import SwiftUI

/// Private DNS (Unbound) + Encrypted DNS (DoH): what they are in plain words,
/// how they're performing, and two maintenance actions.
struct PrivateDNSView: View {
    @Environment(AppModel.self) private var appModel
    @State private var stats: DNSStats?
    @State private var actionMessage: String?
    @State private var isWorking = false

    private var dns: ServiceStatus? {
        appModel.overview?.services.first { $0.id == "unbound" }
    }
    private var encrypted: ServiceStatus? {
        appModel.overview?.services.first { $0.id == "doh" }
    }

    var body: some View {
        List {
            Section {
                statusRow("Private DNS", dns,
                          explain: "Looks up website addresses on your own device instead of your internet provider's servers.")
                statusRow("Encrypted DNS", encrypted,
                          explain: "Wraps those lookups in encryption so no one in between can read them.")
            }

            if let stats {
                Section("Performance") {
                    row("Lookups handled", stats.totalQueries.formatted())
                    row("Answered from memory", stats.cacheHitRate.formatted(.percent.precision(.fractionLength(0))))
                    row("Average speed", stats.avgResponseMs.formatted(.number.precision(.fractionLength(1))) + " ms")
                }
            }

            Section {
                Button {
                    run { try await $0.flushDNSCache() }
                } label: {
                    Label("Clear DNS memory", systemImage: "arrow.counterclockwise")
                }
                Button {
                    run { try await $0.restartPrivateDNS() }
                } label: {
                    Label("Restart Private DNS", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("Harmless fixes to try if some websites suddenly stop loading.")
            }
            .disabled(isWorking)

            if let actionMessage {
                Section {
                    Label(actionMessage, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Private DNS")
        .task {
            stats = try? await appModel.api.dnsStats()
        }
        .refreshable {
            stats = try? await appModel.api.dnsStats()
        }
    }

    private func run(_ action: @escaping (BrickAPI) async throws -> BrickActionResult) {
        isWorking = true
        Task {
            do {
                let result = try await action(appModel.api)
                actionMessage = result.message
            } catch {
                actionMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func statusRow(_ name: String, _ service: ServiceStatus?, explain: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Circle()
                    .fill(service?.running == true ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(service?.running == true ? "On" : "Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(explain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
