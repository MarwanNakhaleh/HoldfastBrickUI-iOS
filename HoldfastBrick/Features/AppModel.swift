import Foundation
import Observation

/// What the remote console needs beyond the API: the device's SSH key and a
/// way to open a shell with it. Bundled so the composition root can swap in
/// fakes (`-mockAPI`, unit tests) without AppModel knowing the difference.
struct RemoteConsoleDependencies {
    let keys: any SSHKeyProviding
    let shell: any RemoteShellConnector

    /// Real keypair in the Keychain + Citadel SSH.
    static func live() -> RemoteConsoleDependencies {
        let store = SSHKeyStore()
        return RemoteConsoleDependencies(keys: store, shell: CitadelShellConnector(keys: store))
    }
}

/// Root application state: whether we're paired, the dashboard overview, and
/// the pairing flow. Feature screens make their own API calls; this model owns
/// only what crosses features.
@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case needsDevice
        case pairing(DiscoveredBrick)
        case connected
    }

    private(set) var phase: Phase = .needsDevice
    private(set) var overview: BrickOverview?
    private(set) var isRefreshing = false
    var lastError: String?

    let api: BrickAPI
    private let tokens: TokenStore
    private let endpoints: EndpointResolver
    private let console: RemoteConsoleDependencies

    init(
        api: BrickAPI,
        tokens: TokenStore,
        endpoints: EndpointResolver,
        console: RemoteConsoleDependencies? = nil
    ) {
        self.api = api
        self.tokens = tokens
        self.endpoints = endpoints
        self.console = console ?? .live()
        if tokens.token != nil, endpoints.hasCandidates {
            phase = .connected
        }
    }

    /// Fresh model for the console screen; SSH dependencies stay at the root.
    func makeRemoteConsoleModel() -> RemoteConsoleModel {
        RemoteConsoleModel(api: api, keys: console.keys, shell: console.shell,
                           endpoints: endpoints)
    }

    var deviceName: String { overview?.deviceName ?? "Holdfast Brick" }

    /// "via Tailscale" / "on your home network" for the Device screen.
    var connectionRoute: String? { endpoints.activeRouteDescription }

    // MARK: - Onboarding

    func startPairing(with brick: DiscoveredBrick) {
        phase = .pairing(brick)
    }

    func cancelPairing() {
        phase = .needsDevice
    }

    /// Exchange the 6-digit code for a token, then immediately learn the
    /// brick's Tailscale addresses so every later connection is route-free.
    func completePairing(brick: DiscoveredBrick, code: String) async throws {
        endpoints.adopt(lanHost: brick.host, port: brick.port)
        let grant = try await api.pair(code: code)
        tokens.save(grant.token)
        if let identity = try? await api.identity() {
            endpoints.learn(from: identity)
        }
        phase = .connected
        await refresh()
    }

    func forgetDevice() {
        tokens.clear()
        endpoints.forget()
        overview = nil
        phase = .needsDevice
    }

    // MARK: - Dashboard

    func refresh() async {
        guard phase == .connected else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            overview = try await api.overview()
            lastError = nil
        } catch BrickError.unauthorized {
            forgetDevice()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Run a mutating action, surface its message on failure, and refresh.
    func perform(_ action: (BrickAPI) async throws -> BrickActionResult) async {
        do {
            let result = try await action(api)
            if !result.ok { lastError = result.message }
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }
}
