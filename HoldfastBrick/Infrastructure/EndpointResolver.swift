import Foundation
import OSLog

/// One way to reach the brick.
struct BrickEndpoint: Codable, Hashable {
    enum Kind: String, Codable {
        case tailscaleDNS   // MagicDNS hostname — survives IP changes, try first
        case tailscaleIP
        case lan
    }

    let kind: Kind
    let host: String
    let port: Int

    var url: URL? { URL(string: "http://\(host):\(port)") }
}

/// Decides which address to use *right now*, so features never know whether
/// they're talking over Tailscale or the home LAN. Candidates are probed in
/// stability order (MagicDNS → Tailscale IP → last-known LAN address) and the
/// winner is cached briefly to keep the dashboard snappy.
final class EndpointResolver: @unchecked Sendable {
    /// Pure ordering policy, unit-tested in isolation.
    static func ordered(_ endpoints: [BrickEndpoint]) -> [BrickEndpoint] {
        let rank: [BrickEndpoint.Kind: Int] = [.tailscaleDNS: 0, .tailscaleIP: 1, .lan: 2]
        return endpoints.sorted { (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
    }

    private let probe: (URL) async -> Bool
    private let defaults: UserDefaults
    private let cacheLifetime: TimeInterval
    private let storageKey = "brickEndpoints"

    private let lock = NSLock()
    private var cachedActive: BrickEndpoint?
    private var cachedAt: Date = .distantPast

    init(
        defaults: UserDefaults = .standard,
        cacheLifetime: TimeInterval = 60,
        probe: ((URL) async -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.cacheLifetime = cacheLifetime
        self.probe = probe ?? Self.httpPing
    }

    // MARK: - Candidate management

    var candidates: [BrickEndpoint] {
        guard let data = defaults.data(forKey: storageKey),
              let endpoints = try? JSONDecoder().decode([BrickEndpoint].self, from: data)
        else { return [] }
        return endpoints
    }

    var hasCandidates: Bool { !candidates.isEmpty }

    /// Called during onboarding with the Bonjour-discovered LAN address.
    func adopt(lanHost: String, port: Int) {
        store([BrickEndpoint(kind: .lan, host: lanHost, port: port)])
    }

    /// Called right after pairing with what the brick says about itself —
    /// this is where the Tailscale addresses come from.
    func learn(from identity: BrickIdentity) {
        var endpoints = candidates.filter { $0.kind == .lan }
        if !identity.lanIP.isEmpty, !endpoints.contains(where: { $0.host == identity.lanIP }) {
            endpoints.append(BrickEndpoint(kind: .lan, host: identity.lanIP, port: identity.port))
        }
        for ip in identity.tailscaleIPs {
            endpoints.append(BrickEndpoint(kind: .tailscaleIP, host: ip, port: identity.port))
        }
        if !identity.magicDNSName.isEmpty {
            endpoints.append(
                BrickEndpoint(kind: .tailscaleDNS, host: identity.magicDNSName, port: identity.port)
            )
        }
        store(Self.ordered(endpoints))
    }

    func forget() {
        defaults.removeObject(forKey: storageKey)
        lock.lock()
        cachedActive = nil
        cachedAt = .distantPast
        lock.unlock()
    }

    // MARK: - Resolution

    /// The endpoint to use right now. Probes candidates in order; throws
    /// `BrickError.unreachable` when none answer.
    func resolve() async throws -> BrickEndpoint {
        if let cached = cachedIfFresh() { return cached }

        for endpoint in Self.ordered(candidates) {
            guard let url = endpoint.url else {
                Self.log.error("candidate \(endpoint.kind.rawValue, privacy: .public) host '\(endpoint.host, privacy: .public)' port \(endpoint.port) makes an invalid URL — skipped")
                continue
            }
            Self.log.info("probing \(url.absoluteString, privacy: .public)")
            if await probe(url) {
                Self.log.info("probe OK — using \(url.absoluteString, privacy: .public)")
                cache(endpoint)
                return endpoint
            }
        }
        Self.log.error("no candidate answered (\(self.candidates.count) tried) — unreachable")
        throw BrickError.unreachable
    }

    private func cachedIfFresh() -> BrickEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard let cachedActive, Date().timeIntervalSince(cachedAt) < cacheLifetime else {
            return nil
        }
        return cachedActive
    }

    private func cache(_ endpoint: BrickEndpoint) {
        lock.lock()
        defer { lock.unlock() }
        cachedActive = endpoint
        cachedAt = Date()
    }

    /// Drop the cached winner (e.g. after a request-level connection failure)
    /// so the next call re-probes from the top.
    func invalidate() {
        lock.lock()
        cachedActive = nil
        cachedAt = .distantPast
        lock.unlock()
    }

    /// For the Settings screen: "via Tailscale" / "on your home network".
    var activeRouteDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        switch cachedActive?.kind {
        case .tailscaleDNS, .tailscaleIP: return "via Tailscale"
        case .lan: return "on your home network"
        case nil: return nil
        }
    }

    // MARK: - Private

    private func store(_ endpoints: [BrickEndpoint]) {
        if let data = try? JSONEncoder().encode(endpoints) {
            defaults.set(data, forKey: storageKey)
        }
        invalidate()
    }

    private static func httpPing(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("/api/v1/ping"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            log.info("ping \(request.url?.absoluteString ?? "?", privacy: .public) -> HTTP \(http.statusCode)")
            return http.statusCode == 200
        } catch {
            log.error("ping \(request.url?.absoluteString ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public) (\((error as NSError).domain, privacy: .public) \((error as NSError).code))")
            return false
        }
    }

    private static let log = Logger(
        subsystem: "com.marwannakhaleh.holdfastbrick", category: "endpoint"
    )
}
