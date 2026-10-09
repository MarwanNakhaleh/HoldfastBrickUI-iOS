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
    /// HTTPS with the household-CA certificate is the default; false marks the
    /// plain-http escape hatch for TLS-less (dev) bricks, which is never
    /// persisted and never allowed to carry the bearer token.
    let secure: Bool

    init(kind: Kind, host: String, port: Int, secure: Bool = true) {
        self.kind = kind
        self.host = host
        self.port = port
        self.secure = secure
    }

    var scheme: String { secure ? "https" : "http" }
    var url: URL? { URL(string: "\(scheme)://\(host):\(port)") }

    var plaintextTwin: BrickEndpoint {
        BrickEndpoint(kind: kind, host: host, port: port, secure: false)
    }

    // Codable: entries persisted before `secure` existed point at the same
    // brick, which serves TLS after the API update — so they decode as secure.
    private enum CodingKeys: String, CodingKey { case kind, host, port, secure }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        secure = try container.decodeIfPresent(Bool.self, forKey: .secure) ?? true
    }
}

/// How the current session trusts the brick's transport.
enum BrickTransportSecurity: Equatable {
    /// TLS with the household-CA certificate: the default, token allowed.
    case secure
    /// A TLS-less brick answered a probe: the token must not be sent until
    /// the user re-pairs.
    case plaintextNeedsRePair
    /// The user re-paired over plaintext this session (a dev brick); the
    /// fresh token may be used until the app relaunches.
    case plaintextPaired
}

/// Decides which address to use *right now*, so features never know whether
/// they're talking over Tailscale or the home LAN. Candidates are probed in
/// stability order (MagicDNS → Tailscale IP → last-known LAN address) and the
/// winner is cached briefly to keep the dashboard snappy.
///
/// Security shape: endpoints default to HTTPS, and only a TLS-validated
/// response may persist endpoints — the household-CA certificate is the
/// identity proof, since only a holder of a cert this phone trusts for this
/// brick can answer. Plain-http answers (a TLS-less dev brick, reported as
/// `cert_fingerprint: null`) work for the session but never reach
/// UserDefaults, and the session then requires re-pairing before any
/// authenticated request goes out.
final class EndpointResolver: @unchecked Sendable {
    /// Pure ordering policy, unit-tested in isolation.
    static func ordered(_ endpoints: [BrickEndpoint]) -> [BrickEndpoint] {
        let rank: [BrickEndpoint.Kind: Int] = [.tailscaleDNS: 0, .tailscaleIP: 1, .lan: 2]
        return endpoints.sorted { (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
    }

    /// What a reachability probe learned. `certFingerprint` is the brick's
    /// TLS certificate SHA-256 as reported by `/ping` (null on TLS-less bricks).
    enum ProbeOutcome {
        case noAnswer
        case answered(certFingerprint: String?)
    }

    private let probe: (URL) async -> ProbeOutcome
    private let defaults: UserDefaults
    private let cacheLifetime: TimeInterval
    private let storageKey = "brickEndpoints"
    private static let fingerprintKey = "brickCertFingerprint"

    private let lock = NSLock()
    private var cachedActive: BrickEndpoint?
    private var cachedAt: Date = .distantPast
    /// Endpoints learned over plain http live here for the session only (H5).
    private var sessionCandidates: [BrickEndpoint]?
    private var transport: BrickTransportSecurity = .secure
    private var fingerprint: String?

    init(
        defaults: UserDefaults = .standard,
        cacheLifetime: TimeInterval = 60,
        probe: ((URL) async -> ProbeOutcome)? = nil
    ) {
        self.defaults = defaults
        self.cacheLifetime = cacheLifetime
        self.probe = probe ?? Self.ping
        fingerprint = defaults.string(forKey: Self.fingerprintKey)
    }

    // MARK: - Candidate management

    var candidates: [BrickEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        if let sessionCandidates { return sessionCandidates }
        return Self.decodeStoredCandidates(defaults, key: storageKey)
    }

    var hasCandidates: Bool { !candidates.isEmpty }

    /// Called during onboarding with the Bonjour-discovered LAN address.
    func adopt(lanHost: String, port: Int) {
        setCandidates([BrickEndpoint(kind: .lan, host: lanHost, port: port)])
    }

    /// Called right after pairing with what the brick says about itself —
    /// this is where the Tailscale addresses come from.
    ///
    /// Endpoints persist only when the session rides TLS: a stored endpoint
    /// is a promise about where the token will be sent later, and TLS with
    /// the household-CA certificate is the only brick-identity proof on
    /// offer. Plain-http responses (dev bricks) stay usable in memory for
    /// the session and are never written to UserDefaults.
    func learn(from identity: BrickIdentity) {
        let secure = isSecureSession
        var endpoints = candidates.filter { $0.kind == .lan }
        if !identity.lanIP.isEmpty, !endpoints.contains(where: { $0.host == identity.lanIP }) {
            endpoints.append(
                BrickEndpoint(kind: .lan, host: identity.lanIP, port: identity.port, secure: secure)
            )
        }
        for ip in identity.tailscaleIPs {
            endpoints.append(
                BrickEndpoint(kind: .tailscaleIP, host: ip, port: identity.port, secure: secure)
            )
        }
        if !identity.magicDNSName.isEmpty {
            endpoints.append(
                BrickEndpoint(
                    kind: .tailscaleDNS, host: identity.magicDNSName, port: identity.port,
                    secure: secure
                )
            )
        }
        setCandidates(Self.ordered(endpoints))
    }

    /// Record what the /pair response said: the fingerprint becomes the
    /// user-facing Brick ID (persisted when present, cleared when null), and
    /// a plaintext pairing licenses this session's token over http.
    func notePairing(certFingerprint: String?) {
        lock.lock()
        defer { lock.unlock() }
        fingerprint = certFingerprint
        if let certFingerprint {
            defaults.set(certFingerprint, forKey: Self.fingerprintKey)
        } else {
            defaults.removeObject(forKey: Self.fingerprintKey)
        }
        if transport == .plaintextNeedsRePair {
            transport = .plaintextPaired
        }
    }

    /// Session-scoped TLS state; HTTPBrickClient gates the token on it.
    var transportSecurity: BrickTransportSecurity {
        lock.lock()
        defer { lock.unlock() }
        return transport
    }

    /// SHA-256 hex of the brick's TLS certificate, from the /pair response.
    /// nil means the brick runs without TLS.
    var certFingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return fingerprint
    }

    func forget() {
        lock.lock()
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: Self.fingerprintKey)
        sessionCandidates = nil
        transport = .secure
        fingerprint = nil
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
            if case .answered = await probe(url) {
                Self.log.info("probe OK — using \(url.absoluteString, privacy: .public)")
                noteAnsweredSecure(endpoint)
                cache(endpoint)
                return endpoint
            }

            // A secure candidate that doesn't answer gets exactly one
            // plaintext check: only a 200 without a certificate fingerprint
            // (a TLS-less dev brick) may flip the session to http.
            if endpoint.secure,
               let fallbackURL = endpoint.plaintextTwin.url,
               case let .answered(fingerprint) = await probe(fallbackURL),
               fingerprint == nil {
                Self.log.info("https dead but plain http answered with a null certificate fingerprint — TLS-less dev brick")
                notePlaintextAnswer()
                let fallback = endpoint.plaintextTwin
                // Convert every candidate so later resolves don't repeat the
                // doomed https probes. Session overlay only — never persisted.
                setCandidates(candidates.map { $0.secure ? $0.plaintextTwin : $0 })
                cache(fallback)
                return fallback
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

    private var isSecureSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return transport == .secure
    }

    private func noteAnsweredSecure(_ endpoint: BrickEndpoint) {
        lock.lock()
        defer { lock.unlock() }
        // A TLS-less session that starts seeing TLS again (brick upgraded
        // mid-session) goes back to the default; a plaintext-paired session
        // stays as-is for its lifetime.
        if endpoint.secure, transport == .plaintextNeedsRePair {
            transport = .secure
        }
    }

    private func notePlaintextAnswer() {
        lock.lock()
        defer { lock.unlock() }
        if transport == .secure {
            transport = .plaintextNeedsRePair
        }
    }

    private func setCandidates(_ endpoints: [BrickEndpoint]) {
        lock.lock()
        defer { lock.unlock() }
        if transport == .secure {
            // Persistence invariant (H5): only TLS-backed endpoints may reach
            // UserDefaults, no matter what a caller passes in.
            let persistable = endpoints.filter(\.secure)
            if persistable.isEmpty {
                sessionCandidates = endpoints
            } else {
                if let data = try? JSONEncoder().encode(persistable) {
                    defaults.set(data, forKey: storageKey)
                }
                sessionCandidates = nil
            }
        } else {
            sessionCandidates = endpoints
        }
        cachedActive = nil
        cachedAt = .distantPast
    }

    private static func decodeStoredCandidates(
        _ defaults: UserDefaults, key: String
    ) -> [BrickEndpoint] {
        guard let data = defaults.data(forKey: key),
              let endpoints = try? JSONDecoder().decode([BrickEndpoint].self, from: data)
        else { return [] }
        return endpoints
    }

    private static func ping(_ base: URL) async -> ProbeOutcome {
        var request = URLRequest(url: base.appendingPathComponent("/api/v1/ping"))
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .noAnswer }
            log.info("ping \(request.url?.absoluteString ?? "?", privacy: .public) -> HTTP \(http.statusCode)")
            guard http.statusCode == 200 else { return .noAnswer }
            struct Ping: Decodable {
                let certFingerprint: String?
                enum CodingKeys: String, CodingKey { case certFingerprint = "cert_fingerprint" }
            }
            let body = try? JSONDecoder().decode(Ping.self, from: data)
            return .answered(certFingerprint: body?.certFingerprint)
        } catch {
            log.error("ping \(request.url?.absoluteString ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public) (\((error as NSError).domain, privacy: .public) \((error as NSError).code))")
            return .noAnswer
        }
    }

    private static let log = Logger(
        subsystem: "com.marwannakhaleh.holdfastbrick", category: "endpoint"
    )
}
