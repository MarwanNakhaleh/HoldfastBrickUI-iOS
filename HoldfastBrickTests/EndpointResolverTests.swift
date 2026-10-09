import XCTest
@testable import HoldfastBrick

final class EndpointResolverTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "EndpointResolverTests")!
        defaults.removePersistentDomain(forName: "EndpointResolverTests")
    }

    private static func answered(certFingerprint: String? = nil) -> EndpointResolver.ProbeOutcome {
        .answered(certFingerprint: certFingerprint)
    }

    private let identity = BrickIdentity(
        deviceName: "Brick", version: "0.1", port: 8787,
        lanIP: "192.168.1.42", tailscaleIPs: ["100.1.2.3"], magicDNSName: "brick.ts.net"
    )

    func testOrderingPrefersTailscaleDNSThenIPThenLAN() {
        let lan = BrickEndpoint(kind: .lan, host: "192.168.1.42", port: 8787)
        let ip = BrickEndpoint(kind: .tailscaleIP, host: "100.1.2.3", port: 8787)
        let dns = BrickEndpoint(kind: .tailscaleDNS, host: "brick.ts.net", port: 8787)

        let ordered = EndpointResolver.ordered([lan, ip, dns])

        XCTAssertEqual(ordered.map(\.kind), [.tailscaleDNS, .tailscaleIP, .lan])
    }

    func testEndpointsDefaultToHTTPS() {
        let endpoint = BrickEndpoint(kind: .lan, host: "192.168.1.42", port: 8787)

        XCTAssertEqual(endpoint.url?.scheme, "https")
        XCTAssertEqual(endpoint.plaintextTwin.url?.scheme, "http")
        XCTAssertFalse(endpoint.plaintextTwin.secure)
    }

    func testLegacyPersistedEndpointsDecodeAsSecure() throws {
        // Endpoints stored before the `secure` field existed (the plain-http
        // era) refer to the same brick, which serves TLS after the update.
        struct Legacy: Codable { let kind: String; let host: String; let port: Int }
        let legacy = try JSONEncoder().encode(
            [Legacy(kind: "lan", host: "192.168.1.42", port: 8787)]
        )
        defaults.set(legacy, forKey: "brickEndpoints")

        let resolver = EndpointResolver(defaults: defaults, probe: { _ in Self.answered() })

        XCTAssertEqual(resolver.candidates.first?.url?.scheme, "https")
    }

    func testResolvePicksFirstReachableCandidate() async throws {
        // Tailscale addresses answer, so LAN must never win.
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.host()?.hasPrefix("100.") ?? false ? Self.answered() : .noAnswer
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        resolver.learn(from: BrickIdentity(
            deviceName: "Brick", version: "0.1", port: 8787,
            lanIP: "192.168.1.42", tailscaleIPs: ["100.1.2.3"], magicDNSName: ""
        ))

        let endpoint = try await resolver.resolve()

        XCTAssertEqual(endpoint.kind, .tailscaleIP)
        XCTAssertEqual(endpoint.host, "100.1.2.3")
        XCTAssertEqual(endpoint.url?.scheme, "https")
    }

    func testResolveFallsBackToLANWhenTailscaleUnreachable() async throws {
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.host()?.hasPrefix("192.168.") ?? false ? Self.answered() : .noAnswer
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        resolver.learn(from: identity)

        let endpoint = try await resolver.resolve()

        XCTAssertEqual(endpoint.kind, .lan)
    }

    func testResolveThrowsUnreachableWhenNothingAnswers() async {
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in .noAnswer })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)

        do {
            _ = try await resolver.resolve()
            XCTFail("expected BrickError.unreachable")
        } catch {
            XCTAssertEqual(error as? BrickError, .unreachable)
        }
    }

    func testWinnerIsCachedUntilInvalidated() async throws {
        var probeCount = 0
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in
            probeCount += 1
            return Self.answered()
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)

        _ = try await resolver.resolve()
        _ = try await resolver.resolve()
        XCTAssertEqual(probeCount, 1, "second resolve should reuse the cached winner")

        resolver.invalidate()
        _ = try await resolver.resolve()
        XCTAssertEqual(probeCount, 2, "invalidate() should force a re-probe")
    }

    func testForgetClearsCandidates() {
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in Self.answered() })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        XCTAssertTrue(resolver.hasCandidates)

        resolver.forget()

        XCTAssertFalse(resolver.hasCandidates)
    }

    // MARK: - TLS-validated persistence (H5)

    func testHTTPSAnswersPersistLearnedEndpoints() async throws {
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in Self.answered() })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)

        resolver.learn(from: identity)
        let endpoint = try await resolver.resolve()

        XCTAssertEqual(endpoint.url?.scheme, "https")
        XCTAssertNotNil(defaults.data(forKey: "brickEndpoints"),
                        "endpoints learned over a TLS-validated response must persist")
        let reloaded = EndpointResolver(defaults: defaults, probe: { _ in Self.answered() })
        XCTAssertEqual(reloaded.candidates.map(\.host).sorted(), ["100.1.2.3", "192.168.1.42", "brick.ts.net"].sorted())
    }

    func testPlainHTTPBrickAnswersButNeverPersists() async throws {
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.scheme == "https" ? .noAnswer : Self.answered(certFingerprint: nil)
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        resolver.learn(from: identity)

        let endpoint = try await resolver.resolve()

        XCTAssertEqual(endpoint.url?.scheme, "http", "a TLS-less brick must be reachable")
        XCTAssertEqual(resolver.transportSecurity, .plaintextNeedsRePair)
        let stored = try JSONDecoder().decode(
            [BrickEndpoint].self, from: defaults.data(forKey: "brickEndpoints")!
        )
        XCTAssertTrue(stored.allSatisfy(\.secure),
                      "no plain-http endpoint may ever reach UserDefaults")
    }

    func testPlainHTTPFallbackRequiresNullFingerprint() async {
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.scheme == "https" ? .noAnswer : Self.answered(certFingerprint: "aabbccdd")
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)

        do {
            _ = try await resolver.resolve()
            XCTFail("plain http with a certificate fingerprint is not a valid TLS-less brick")
        } catch {
            XCTAssertEqual(error as? BrickError, .unreachable)
        }
        XCTAssertEqual(resolver.transportSecurity, .secure)
    }

    // MARK: - Pairing state

    func testNotePairingStoresFingerprintAndClearsOnNull() {
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in Self.answered() })

        resolver.notePairing(certFingerprint: "abcd1234")
        XCTAssertEqual(resolver.certFingerprint, "abcd1234")
        XCTAssertEqual(defaults.string(forKey: "brickCertFingerprint"), "abcd1234")
        XCTAssertEqual(resolver.transportSecurity, .secure)

        resolver.notePairing(certFingerprint: nil)
        XCTAssertNil(resolver.certFingerprint)
        XCTAssertNil(defaults.string(forKey: "brickCertFingerprint"))
    }

    func testPlaintextPairingLicensesTheSessionToken() async throws {
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.scheme == "https" ? .noAnswer : Self.answered(certFingerprint: nil)
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        _ = try await resolver.resolve()
        XCTAssertEqual(resolver.transportSecurity, .plaintextNeedsRePair)

        resolver.notePairing(certFingerprint: nil)

        XCTAssertEqual(resolver.transportSecurity, .plaintextPaired)
    }

    func testForgetResetsTransportStateAndFingerprint() async throws {
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.scheme == "https" ? .noAnswer : Self.answered(certFingerprint: nil)
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        _ = try await resolver.resolve()
        resolver.notePairing(certFingerprint: nil)

        resolver.forget()

        XCTAssertEqual(resolver.transportSecurity, .secure)
        XCTAssertNil(resolver.certFingerprint)
        XCTAssertFalse(resolver.hasCandidates)
    }
}
