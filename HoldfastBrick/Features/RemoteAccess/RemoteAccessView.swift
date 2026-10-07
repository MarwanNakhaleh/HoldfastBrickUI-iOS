import SwiftUI

/// Remote Access (Tailscale): the on/off switch and which of your devices
/// are part of your private network.
struct RemoteAccessView: View {
    @Environment(AppModel.self) private var appModel
    @State private var status: RemoteAccessStatus?
    @State private var isToggling = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: toggleBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remote access").font(.headline)
                        Text("Reach your Holdfast Brick securely when you're away from home")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isToggling)
            } footer: {
                Text("Powered by Tailscale — a private, encrypted connection between your own devices. Nothing is exposed to the open internet.")
            }

            if let status, !status.tailscaleIPs.isEmpty {
                Section("This device's private address") {
                    ForEach(status.tailscaleIPs, id: \.self) { ip in
                        Text(ip).monospaced().font(.footnote)
                    }
                }
            }

            if let peers = status?.peers, !peers.isEmpty {
                Section("Your devices") {
                    ForEach(peers) { peer in
                        HStack {
                            Image(systemName: icon(for: peer.os))
                                .foregroundStyle(peer.online ? Color.accentColor : Color.secondary)
                            Text(peer.hostname)
                            Spacer()
                            Text(peer.online ? "Online" : "Offline")
                                .font(.caption)
                                .foregroundStyle(peer.online ? Color.green : Color.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Remote Access")
        .task { status = try? await appModel.api.remoteAccessStatus() }
        .refreshable { status = try? await appModel.api.remoteAccessStatus() }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { status?.isRunning ?? false },
            set: { enabled in
                isToggling = true
                Task {
                    await appModel.perform { try await $0.setRemoteAccess(enabled: enabled) }
                    status = try? await appModel.api.remoteAccessStatus()
                    isToggling = false
                }
            }
        )
    }

    private func icon(for os: String) -> String {
        switch os.lowercased() {
        case "ios": return "iphone"
        case "macos": return "laptopcomputer"
        case "windows": return "pc"
        case "linux": return "server.rack"
        default: return "desktopcomputer"
        }
    }
}
