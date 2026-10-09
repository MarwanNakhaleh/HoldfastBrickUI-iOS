import SwiftUI

/// The physical brick: health, connection route, reboot, unpair.
struct DeviceView: View {
    /// Where the "Update brick" flow currently is.
    private enum UpdatePhase: Equatable {
        case idle
        case running(String)
        case upToDate
        case failed(String)
    }

    @Environment(AppModel.self) private var appModel
    @State private var health: DeviceHealth?
    @State private var showRebootConfirm = false
    @State private var showForgetConfirm = false
    @State private var rebooting = false
    @State private var updatePhase: UpdatePhase = .idle
    @State private var updateTask: Task<Void, Never>?

    private var isUpdating: Bool {
        if case .running = updatePhase { return true }
        return false
    }

    var body: some View {
        List {
            if let health {
                Section("Health") {
                    row("Name", health.hostname)
                    row("Up for", health.uptime)
                    if let temp = health.cpuTempCelsius {
                        row("Temperature", temp.formatted(.number.precision(.fractionLength(1))) + " °C")
                    }
                    if let used = health.memoryUsedMb, let total = health.memoryTotalMb {
                        row("Memory", "\(used) / \(total) MB")
                    }
                    if let disk = health.diskUsedPercent {
                        row("Storage used", disk)
                    }
                    if let version = health.dietpiVersion {
                        row("System version", "DietPi \(version)")
                    }
                }
            }

            if let route = appModel.connectionRoute {
                Section("Connection") {
                    Label(route.capitalized, systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let brickID = appModel.brickID {
                    row("Brick ID", brickID)
                        .accessibilityIdentifier("device.brickID")
                } else {
                    Label("This brick is running an older, less secure setup. Re-pair to upgrade it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("device.insecureWarning")
                }
            } header: {
                Text("Security")
            } footer: {
                Text(appModel.brickID == nil
                     ? "Re-pairing sets up an encrypted connection between this phone and your Holdfast Brick."
                     : "Compare this ID with the one the Holdfast Brick prints in its console to confirm you're connected to your own device.")
            }

            Section {
                Button {
                    startUpdate()
                } label: {
                    if case let .running(message) = updatePhase {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Updating…")
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Label("Update brick", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isUpdating)
                .accessibilityIdentifier("device.updateButton")

                switch updatePhase {
                case .upToDate:
                    Label("Up to date", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("device.updateUpToDate")
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                case .idle, .running:
                    EmptyView()
                }
            } footer: {
                Text("Downloads and installs the latest Holdfast software. Protection keeps running while it updates.")
            }

            Section {
                NavigationLink {
                    RemoteConsoleView(model: appModel.makeRemoteConsoleModel())
                } label: {
                    Label("Remote console", systemImage: "terminal")
                }
                .accessibilityIdentifier("device.consoleLink")
            } footer: {
                Text("Advanced: run commands directly on your Holdfast Brick over SSH.")
            }

            Section {
                Button {
                    showRebootConfirm = true
                } label: {
                    Label(rebooting ? "Rebooting…" : "Restart device",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(rebooting)
                .accessibilityIdentifier("device.rebootButton")
            } footer: {
                Text("Restarting takes about a minute. Internet keeps working through your router while the Holdfast Brick is down — only filtering pauses.")
            }

            Section {
                Button(role: .destructive) {
                    showForgetConfirm = true
                } label: {
                    Label("Forget this device", systemImage: "xmark.circle")
                }
            } footer: {
                Text("Removes this phone's pairing. The Holdfast Brick keeps protecting your network.")
            }
        }
        .navigationTitle("Device")
        .confirmationDialog("Restart your Holdfast Brick?",
                            isPresented: $showRebootConfirm, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { reboot() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Filtering pauses for about a minute while it restarts.")
        }
        .confirmationDialog("Forget this device?",
                            isPresented: $showForgetConfirm, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                Task { await appModel.forgetDevice() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { health = try? await appModel.api.deviceHealth() }
        .refreshable { health = try? await appModel.api.deviceHealth() }
        .onDisappear {
            updateTask?.cancel()
            updateTask = nil
        }
    }

    /// Kick off a software update, then poll (bounded) until the brick reports
    /// it's done, and refresh the device info. The task is cancelled if the
    /// user leaves the screen — the update itself keeps running on the brick.
    private func startUpdate() {
        updatePhase = .running("Starting update…")
        updateTask = Task {
            do {
                let result = try await appModel.api.startUpdate()
                updatePhase = .running(result.message)

                var finished = false
                for _ in 0 ..< 40 { // ~2 minutes at one poll every 3 seconds
                    try? await Task.sleep(for: .seconds(3))
                    if Task.isCancelled { return }
                    guard let status = try? await appModel.api.updateStatus() else { continue }
                    if !status.running {
                        finished = true
                        break
                    }
                }

                if finished {
                    health = try? await appModel.api.deviceHealth()
                    await appModel.refresh()
                    updatePhase = .upToDate
                } else {
                    updatePhase = .failed("The update is taking longer than expected. Check back in a few minutes.")
                }
            } catch {
                updatePhase = .failed(error.localizedDescription)
            }
        }
    }

    private func reboot() {
        rebooting = true
        Task {
            _ = try? await appModel.api.rebootDevice()
            // Give the brick time to go down and come back before refreshing.
            try? await Task.sleep(for: .seconds(5))
            rebooting = false
            await appModel.refresh()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
