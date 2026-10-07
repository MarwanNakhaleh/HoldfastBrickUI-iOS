import SwiftUI

/// Network Monitor (ntopng): who's on the network and how much they're talking.
struct NetworkMonitorView: View {
    @Environment(AppModel.self) private var appModel
    @State private var devices: [NetworkDevice] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if devices.isEmpty && !isLoading && errorMessage == nil {
                ContentUnavailableView(
                    "No devices seen yet",
                    systemImage: "wifi",
                    description: Text("Devices using your network will appear here.")
                )
            }

            ForEach(devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(device.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(device.ip)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospaced()
                    }
                    HStack(spacing: 14) {
                        Label(format(bytes: device.bytesReceived), systemImage: "arrow.down")
                        Label(format(bytes: device.bytesSent), systemImage: "arrow.up")
                        if device.activeFlows > 0 {
                            Label("\(device.activeFlows)", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Network Monitor")
        .overlay { if isLoading && devices.isEmpty { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await appModel.api.networkDevices()
                .sorted { $0.bytesReceived + $0.bytesSent > $1.bytesReceived + $1.bytesSent }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func format(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
