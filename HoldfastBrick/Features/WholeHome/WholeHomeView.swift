import SwiftUI

/// Guided flow to make the brick the network's DHCP server, so every device
/// that joins the WiFi is protected automatically — no per-device setup.
struct WholeHomeView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: WholeHomeModel?
    @State private var showDisableConfirm = false

    var body: some View {
        List {
            if let model {
                content(for: model)

                if let message = model.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("wholehome.error")
                    }
                }
            }
        }
        .overlay {
            if model == nil || model?.state == .loading { ProgressView() }
        }
        .navigationTitle("Whole-Home Protection")
        .task {
            if model == nil { model = WholeHomeModel(api: appModel.api) }
            await model?.load()
        }
        .refreshable { await model?.load() }
        .confirmationDialog("Turn off whole-home protection?",
                            isPresented: $showDisableConfirm, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) {
                Task { await model?.disable() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your router takes over handing out addresses again, and new devices are no longer protected automatically.")
        }
    }

    // MARK: - States

    @ViewBuilder
    private func content(for model: WholeHomeModel) -> some View {
        switch model.state {
        case .loading:
            EmptyView()
        case .intro:
            introSection(model)
        case let .blocked(check, router):
            blockedSections(model, check: check, router: router)
        case .ready:
            readySection(model)
        case let .enabled(status):
            enabledSections(model, status: status)
        }
    }

    private func introSection(_ model: WholeHomeModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Protect every device at once", systemImage: "house.fill")
                    .font(.headline)
                Text("Your Holdfast Brick can hand out network addresses itself. Every phone, TV, and gadget on your WiFi then gets ad blocking and private DNS automatically — nothing to set up per device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            actionButton("Check my network", isWorking: model.isWorking,
                         identifier: "wholehome.checkButton") {
                await model.check()
            }
        } footer: {
            Text("First we make sure your router isn't already doing this job.")
        }
    }

    @ViewBuilder
    private func blockedSections(_ model: WholeHomeModel, check: DHCPCheck, router: RouterInfo?) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(blockerHeadline(check: check, router: router),
                      systemImage: "exclamationmark.shield")
                    .font(.headline)
                if check.otherDHCP == .error, !check.otherDHCPError.isEmpty {
                    Text(check.otherDHCPError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Two address-givers on one network confuse your devices, so the router's has to go off before the brick takes over.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        Section("Turn off your router's DHCP") {
            let steps = RouterInstructions.steps(for: router?.vendorKey ?? .unknown)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .bold()
                        .foregroundStyle(.tint)
                    Text(step)
                }
                .font(.callout)
            }

            if let url = portalURL(router) {
                Link(destination: url) {
                    Label("Open router settings", systemImage: "safari")
                }
                .accessibilityIdentifier("wholehome.portalLink")
            }
        }

        Section {
            actionButton("Check again", isWorking: model.isWorking,
                         identifier: "wholehome.recheckButton") {
                await model.check()
            }
        }
    }

    private func readySection(_ model: WholeHomeModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your router's DHCP is off", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("The brick is ready to take over handing out addresses. Devices switch over on their own as they renew — usually within minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            actionButton("Turn on whole-home protection", isWorking: model.isWorking,
                         identifier: "wholehome.enableButton") {
                await model.enable()
            }

            // A 422 from enable means the brick couldn't pin its own IP
            // automatically — without this note, retapping the same button
            // is a dead end.
            if model.errorMessage != nil {
                Text("Follow the steps above on the brick, then tap the button again — the check re-runs each time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("wholehome.staticIPHint")
            }
        }
    }

    @ViewBuilder
    private func enabledSections(_ model: WholeHomeModel, status: DHCPStatus) -> some View {
        Section {
            Label("On — brick manages your network", systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.green)
        }

        Section("Network") {
            row("Gateway", status.gateway)
            row("Address range", "\(status.rangeStart) – \(status.rangeEnd)")
            row("Devices with addresses", status.leaseCount.formatted())
        }

        if model.needsReboot {
            Section {
                Button {
                    Task { await model.reboot() }
                } label: {
                    Label("Restart to finish setup", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("wholehome.rebootButton")
            } footer: {
                Text("One quick restart lets the brick take over cleanly. Internet keeps working through your router while it's down.")
            }
        }

        Section {
            Button(role: .destructive) {
                showDisableConfirm = true
            } label: {
                Label("Turn off", systemImage: "xmark.circle")
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("wholehome.disableButton")
        } footer: {
            Text("Turn your router's DHCP back on first if you do this, or new devices won't get network addresses.")
        }
    }

    // MARK: - Helpers

    private func blockerHeadline(check: DHCPCheck, router: RouterInfo?) -> String {
        let vendor = router.map { " (\($0.vendor))" } ?? ""
        return check.otherDHCP == .yes
            ? "Your router\(vendor) is still handing out addresses."
            : "Couldn't confirm your router\(vendor) stopped handing out addresses."
    }

    /// Only ever open plain web URLs the brick handed us.
    private func portalURL(_ router: RouterInfo?) -> URL? {
        guard let router,
              let url = URL(string: router.portalURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func actionButton(_ title: String, isWorking: Bool, identifier: String,
                              action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            if isWorking {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text(title).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isWorking)
        .accessibilityIdentifier(identifier)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
