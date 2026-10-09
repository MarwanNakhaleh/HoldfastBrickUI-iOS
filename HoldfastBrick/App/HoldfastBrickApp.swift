import SwiftUI

/// Composition root — the one place that knows concrete types. Everything
/// inward receives dependencies through the Domain/Ports protocols.
@main
struct HoldfastBrickApp: App {
    @State private var appModel: AppModel
    @State private var locator: any DeviceLocator

    init() {
        // `-mockAPI` (UI tests, demos) wires the whole app to an in-memory
        // brick: no network, pairing code 123456, instant "discovery".
        // Debug-only: the UI-test scheme runs the Debug configuration, so the
        // launch-argument backdoor never compiles into Release builds.
        #if DEBUG
        if CommandLine.arguments.contains("-mockAPI") {
            let mockDefaults = UserDefaults(suiteName: "mock")!
            let tokens = MemoryTokenStore()
            _appModel = State(initialValue: AppModel(
                api: MockBrickAPI(),
                tokens: tokens,
                endpoints: EndpointResolver(
                    defaults: mockDefaults,
                    probe: { _ in .answered(certFingerprint: MockBrickAPI.certFingerprint) }
                ),
                console: RemoteConsoleDependencies(keys: MockSSHKeys(), shell: MockRemoteShell()),
                defaults: mockDefaults
            ))
            _locator = State(initialValue: MockDeviceLocator())
            return
        }
        #endif
        let tokens = KeychainTokenStore()
        let resolver = EndpointResolver()
        _appModel = State(initialValue: AppModel(
            api: HTTPBrickClient(resolver: resolver, tokens: tokens),
            tokens: tokens,
            endpoints: resolver
        ))
        _locator = State(initialValue: BonjourDiscovery())
    }

    var body: some Scene {
        WindowGroup {
            RootView(locator: locator)
                .environment(appModel)
        }
    }
}
