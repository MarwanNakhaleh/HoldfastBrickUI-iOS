import SwiftUI

/// Enter the 6-digit code shown by `holdfastbrick-pair` on the device.
struct PairingView: View {
    @Environment(AppModel.self) private var appModel
    let brick: DiscoveredBrick

    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Connect to \(brick.name)")
                    .font(.title2.bold())

                Text("Enter the 6-digit code shown by your Holdfast Brick. If you don't have one, run “holdfastbrick-pair” on the device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($codeFieldFocused)
                    .onChange(of: code) { _, newValue in
                        code = String(newValue.filter(\.isNumber).prefix(6))
                    }
                    .padding()
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 48)
                    .accessibilityIdentifier("pairing.codeField")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .accessibilityIdentifier("pairing.error")
                }

                Button {
                    pair()
                } label: {
                    if isPairing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code.count != 6 || isPairing)
                .padding(.horizontal, 48)
                .accessibilityIdentifier("pairing.connectButton")

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { appModel.cancelPairing() }
                }
            }
            .onAppear { codeFieldFocused = true }
        }
    }

    private func pair() {
        isPairing = true
        errorMessage = nil
        Task {
            do {
                try await appModel.completePairing(brick: brick, code: code)
            } catch {
                errorMessage = error.localizedDescription
                code = ""
            }
            isPairing = false
        }
    }
}
