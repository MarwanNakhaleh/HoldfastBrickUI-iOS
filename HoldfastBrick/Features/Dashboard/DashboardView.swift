import SwiftUI

/// Home screen: one big "you're protected" statement, then a card per
/// protection layer. Everything is layperson vocabulary.
struct DashboardView: View {
    @Environment(AppModel.self) private var appModel

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    protectionHeader

                    if let error = appModel.lastError {
                        errorBanner(error)
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(appModel.overview?.services ?? []) { service in
                            NavigationLink(value: service.id) {
                                ServiceCard(service: service)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("dashboard.card.\(service.id)")
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle(appModel.deviceName)
            .navigationDestination(for: String.self) { serviceID in
                destination(for: serviceID)
            }
            .refreshable { await appModel.refresh() }
            .task { await appModel.refresh() }
        }
    }

    private var protected: Bool { appModel.overview?.protected ?? false }

    private var protectionHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: protected ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(protected ? Color.green : Color.orange)
                .symbolEffect(.pulse, isActive: appModel.isRefreshing)

            Text(protected ? "You're protected" : "Needs attention")
                .font(.title2.bold())
                .accessibilityIdentifier("dashboard.protectionBadge")

            Text(protected
                 ? "Ads and trackers are being blocked for every device on your network."
                 : "One of your protection layers is off. Tap a card below to fix it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
            Text(message).font(.footnote)
            Spacer()
            Button("Retry") { Task { await appModel.refresh() } }
                .font(.footnote.bold())
        }
        .padding(12)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .accessibilityIdentifier("dashboard.errorBanner")
    }

    @ViewBuilder
    private func destination(for serviceID: String) -> some View {
        switch serviceID {
        case "adguard": AdBlockingView()
        case "unbound", "doh": PrivateDNSView()
        case "tailscale": RemoteAccessView()
        case "nextdns": CloudFilteringView()
        case "ntopng": NetworkMonitorView()
        case "system": DeviceView()
        default: Text("Coming soon")
        }
    }
}

/// One protection layer on the grid.
struct ServiceCard: View {
    let service: ServiceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(service.running ? Color.accentColor : Color.secondary)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            Text(service.name)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private var icon: String {
        switch service.id {
        case "adguard": return "hand.raised.fill"
        case "unbound": return "network.badge.shield.half.filled"
        case "doh": return "lock.fill"
        case "tailscale": return "globe"
        case "nextdns": return "cloud.fill"
        case "ntopng": return "chart.bar.fill"
        case "system": return "cpu"
        default: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        if !service.installed { return .gray }
        return service.running ? .green : .orange
    }

    private var statusText: String {
        if !service.installed { return "Not set up" }
        return service.running ? "On" : "Off"
    }
}
