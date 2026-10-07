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
        if CommandLine.arguments.contains("-mockAPI") {
            let tokens = MemoryTokenStore()
            _appModel = State(initialValue: AppModel(
                api: MockBrickAPI(),
                tokens: tokens,
                endpoints: EndpointResolver(
                    defaults: UserDefaults(suiteName: "mock")!,
                    probe: { _ in true }
                ),
                console: RemoteConsoleDependencies(keys: MockSSHKeys(), shell: MockRemoteShell())
            ))
            _locator = State(initialValue: MockDeviceLocator())
        } else {
            let tokens = KeychainTokenStore()
            let resolver = EndpointResolver()
            _appModel = State(initialValue: AppModel(
                api: HTTPBrickClient(resolver: resolver, tokens: tokens),
                tokens: tokens,
                endpoints: resolver
            ))
            _locator = State(initialValue: BonjourDiscovery())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(locator: locator)
                .environment(appModel)
        }
    }
}
