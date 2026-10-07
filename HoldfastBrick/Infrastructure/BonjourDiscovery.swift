import Foundation
import Network
import Observation
import OSLog

/// Browses for `_holdfastbrick._tcp` over Bonjour and resolves each service to
/// host:port. Used only on first run (or re-pairing) — after pairing, the
/// EndpointResolver's stored candidates take over.
@Observable
@MainActor
final class BonjourDiscovery: DeviceLocator {
    private static let log = Logger(
        subsystem: "com.marwannakhaleh.holdfastbrick", category: "discovery"
    )

    private(set) var found: [DiscoveredBrick] = []

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolvers: [NWConnection] = []
    /// Services with a resolver in flight — Bonjour re-announces results on
    /// every network flap, and without this each announcement would spawn a
    /// fresh connection, accumulating without bound for the screen's lifetime.
    @ObservationIgnored private var resolving: Set<String> = []
    /// Bumped on every stop() so timeout tasks from a previous discovery
    /// session can't retry or clear `resolving` against the new session.
    @ObservationIgnored private var generation = 0

    func start() {
        stop()
        found = []

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_holdfastbrick._tcp", domain: nil),
            using: params
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        generation += 1
        browser?.cancel()
        browser = nil
        resolvers.forEach { $0.cancel() }
        resolvers = []
        resolving = []
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            guard !resolving.contains(name),
                  !found.contains(where: { $0.id == name })
            else { continue }
            resolving.insert(name)
            startResolver(for: result.endpoint, name: name, forceIPv4: true)
        }
    }

    /// Cancel a finished/abandoned resolver and drop our strong reference.
    private func prune(_ connection: NWConnection?) {
        guard let connection else { return }
        connection.cancel()
        resolvers.removeAll { $0 === connection }
    }

    /// A throwaway TCP connection resolves the service to a concrete
    /// host:port; it's cancelled the moment we have the address.
    /// IPv4 is tried first — an IPv6 link-local answer (fe80::…%en0) makes a
    /// hostile URL host — but if nothing answers within `Self.ipv4Timeout`
    /// the resolver retries once allowing IPv6, so IPv6-only networks
    /// (e.g. NAT64, used by App Review) still discover the brick.
    private static let ipv4Timeout: Duration = .seconds(3)

    private func startResolver(for serviceEndpoint: NWEndpoint, name: String, forceIPv4: Bool) {
        let params = NWParameters.tcp
        if forceIPv4,
           let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        Self.log.info("resolving \(name, privacy: .public) forceIPv4=\(forceIPv4)")
        let connection = NWConnection(to: serviceEndpoint, using: params)
        resolvers.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Self.log.info("resolver \(name, privacy: .public) state: \(String(describing: state), privacy: .public)")
            guard case .ready = state,
                  let endpoint = connection?.currentPath?.remoteEndpoint,
                  case let .hostPort(host, port) = endpoint
            else { return }
            let brick = DiscoveredBrick(
                id: name,
                name: name,
                host: Self.hostString(host),
                port: Int(port.rawValue)
            )
            Self.log.info("resolved \(name, privacy: .public) -> \(brick.host, privacy: .public):\(brick.port)")
            Task { @MainActor in
                guard let self else { return }
                self.found.removeAll { $0.id == brick.id }
                self.found.append(brick)
                self.resolving.remove(name)
                self.prune(connection)
            }
        }
        connection.start(queue: .main)

        let gen = generation
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: Self.ipv4Timeout)
            guard let self,
                  self.generation == gen,                    // same session
                  self.browser != nil,                       // still discovering
                  !self.found.contains(where: { $0.id == name })
            else { return }
            self.prune(connection)
            if forceIPv4 {
                Self.log.info("IPv4 resolve of \(name, privacy: .public) timed out — retrying with IPv6 allowed")
                self.startResolver(for: serviceEndpoint, name: name, forceIPv4: false)
            } else {
                // Both attempts came up dry — let a future Bonjour
                // announcement trigger a fresh resolve.
                Self.log.info("resolve of \(name, privacy: .public) gave up")
                self.resolving.remove(name)
            }
        }
    }

    nonisolated static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address):
            // Network.framework attaches the resolving interface as a zone
            // ("10.0.0.230%en0"). An IPv4 URL host never needs it, and the
            // bare "%" makes URL(string:) reject the whole URL.
            return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case let .ipv6(address):
            // A zone ID ("fe80::1%en0") must be percent-encoded (RFC 6874)
            // or URL(string:) rejects the whole URL.
            let text = "\(address)".replacingOccurrences(of: "%", with: "%25")
            return "[\(text)]"
        case let .name(name, _): return name
        @unknown default: return "\(host)"
        }
    }
}
