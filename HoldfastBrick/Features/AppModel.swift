import Foundation
import Observation
import OSLog

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
    private let defaults: UserDefaults

    private static let log = Logger(
        subsystem: "com.marwannakhaleh.holdfastbrick", category: "session"
    )

    init(
        api: BrickAPI,
        tokens: TokenStore,
        endpoints: EndpointResolver,
        console: RemoteConsoleDependencies? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.tokens = tokens
        self.endpoints = endpoints
        self.console = console ?? .live()
        self.defaults = defaults
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

    /// First-4/last-4 hex of the brick's TLS certificate fingerprint, for the
    /// user to compare with the console output. nil when the brick runs
    /// without TLS (a dev brick).
    var brickID: String? {
        guard let fingerprint = endpoints.certFingerprint else { return nil }
        let hex = fingerprint.uppercased()
        guard hex.count >= 8 else { return hex }
        return "\(hex.prefix(4))…\(hex.suffix(4))"
    }

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
        // Must precede identity(): on a TLS-less (dev) brick the pairing is
        // what licenses this session's token over plain http.
        endpoints.notePairing(certFingerprint: grant.certFingerprint)
        tokens.save(grant.token)
        if let identity = try? await api.identity() {
            endpoints.learn(from: identity)
        }
        phase = .connected
        await refresh()
    }

    /// Undo pairing: best-effort remote cleanup first (while the token still
    /// works), then every local trace. The remote step is swallowed with a
    /// log — forgetting must always succeed from the user's point of view.
    func forgetDevice() async {
        do {
            _ = try await api.removeSSHKey()
        } catch {
            Self.log.error("remote SSH-key removal skipped (continuing): \(error.localizedDescription, privacy: .public)")
        }
        tokens.clear()
        endpoints.forget()
        overview = nil
        lastError = nil
        phase = .needsDevice

        defaults.removeObject(forKey: RemoteConsoleModel.enabledKey)
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("sshTrustedHostKey:") {
            defaults.removeObject(forKey: key)
        }
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
            await forgetDevice()
        } catch BrickError.insecureTransport {
            // A TLS-minted token can't ride a plain-http fallback; the only
            // way forward is re-pairing.
            await forgetDevice()
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
