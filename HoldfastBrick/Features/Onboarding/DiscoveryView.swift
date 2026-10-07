import SwiftUI

/// First run: find the brick on the home network. No IPs, no ports —
/// just "we found your device".
struct DiscoveryView: View {
    @Environment(AppModel.self) private var appModel
    let locator: any DeviceLocator

    /// How long to search before admitting we can't find anything.
    private static let searchTimeout: Duration = .seconds(15)
    @State private var searchTimedOut = false
    @State private var searchAttempt = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            Text("Welcome to Holdfast")
                .font(.title.bold())

            Text("Make sure your Holdfast Brick is plugged into your router and powered on, and that this phone is on your home WiFi.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if locator.found.isEmpty {
                if searchTimedOut {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("Couldn't find your Holdfast Brick")
                            .font(.headline)
                        Text("Check that it's plugged in and powered on, and that this device is on the same WiFi network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Search Again") {
                            searchTimedOut = false
                            searchAttempt += 1
                            locator.stop()
                            locator.start()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("discovery.retryButton")
                    }
                    .padding(.top, 16)
                    .accessibilityIdentifier("discovery.timeout")
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for your Holdfast Brick…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 16)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(locator.found) { brick in
                        Button {
                            appModel.startPairing(with: brick)
                        } label: {
                            HStack {
                                Image(systemName: "externaldrive.badge.wifi")
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text(brick.name).font(.headline)
                                    Text("Found on your network")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding()
                            .background(.quaternary.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("discovery.device.\(brick.id)")
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            Text("Your data never leaves your home. The app talks directly to the device — there's no cloud account.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom)
        }
        .onAppear { locator.start() }
        .onDisappear { locator.stop() }
        .task(id: searchAttempt) {
            try? await Task.sleep(for: Self.searchTimeout)
            if !Task.isCancelled, locator.found.isEmpty {
                searchTimedOut = true
            }
        }
    }
}
