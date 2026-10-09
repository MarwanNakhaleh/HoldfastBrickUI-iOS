import SwiftUI

/// SSH console to the brick. First visit explains what enabling does and
/// installs this phone's key; after that it connects straight away and offers
/// a monospaced command/output scrollback.
struct RemoteConsoleView: View {
    @State private var model: RemoteConsoleModel
    @State private var command = ""

    init(model: RemoteConsoleModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if model.isEnabled {
                console
            } else {
                explainer
            }
        }
        .navigationTitle("Remote console")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            let model = model
            Task { await model.disconnect() }
        }
    }

    // MARK: - Enable flow

    private var explainer: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "terminal")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Advanced: direct access")
                .font(.title2.bold())

            Text("The remote console gives this phone full administrator (root) access to your Holdfast Brick over SSH. It installs this phone's key on the device — you can run any command, including ones that break things. Only enable it if you know your way around a Linux shell.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let error = model.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("console.error")
            }

            if case let .awaitingCode(expiresAt) = model.state {
                VStack(spacing: 12) {
                    Text("A 6-digit code is now shown on the brick's screen. Enter it here to prove you're physically at the brick.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    TextField("Code from the brick", text: $model.confirmCode)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .font(.title3.monospacedDigit())
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .accessibilityIdentifier("console.confirmCode")
                    Text("Expires at \(expiresAt.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            await model.confirmEnable()
                            if model.isEnabled { await model.connect() }
                        }
                    } label: {
                        if model.isEnabling {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Confirm").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.confirmCode.trimmingCharacters(in: .whitespaces).isEmpty || model.isEnabling)
                    .accessibilityIdentifier("console.confirmButton")
                }
            } else {
                Button {
                    Task {
                        await model.beginEnable()
                        if model.isEnabled { await model.connect() }
                    }
                } label: {
                    if model.isEnabling {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Enable remote console").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isEnabling)
                .padding(.horizontal, 48)
                .accessibilityIdentifier("console.enableButton")
            }

            Spacer()
        }
    }

    // MARK: - Console

    private var console: some View {
        VStack(spacing: 0) {
            statusBar

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("# \(entry.command)")
                                .font(.system(.footnote, design: .monospaced).bold())
                                .foregroundStyle(.secondary)
                            if !entry.output.isEmpty {
                                Text(entry.output)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)

            Divider()

            HStack(spacing: 8) {
                TextField("command", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit(send)
                    .accessibilityIdentifier("console.commandField")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSend)
                .accessibilityIdentifier("console.runButton")
            }
            .padding(12)
        }
        .task { await model.connect() }
    }

    private var statusBar: some View {
        Group {
            switch model.state {
            case .disconnected, .awaitingCode:
                EmptyView()
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting…").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(8)
            case .connected:
                Label("Connected as \(RemoteConsoleModel.username)", systemImage: "circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(8)
            case let .failed(message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("console.error")
                    Button("Try again") {
                        Task { await model.connect() }
                    }
                    .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding(8)
            }
        }
        .background(.quaternary.opacity(0.3))
    }

    private var canSend: Bool {
        model.state == .connected && !model.isRunning
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let entered = command
        command = ""
        Task { await model.run(entered) }
    }
}
