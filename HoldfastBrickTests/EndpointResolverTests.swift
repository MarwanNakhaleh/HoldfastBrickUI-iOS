import XCTest
@testable import HoldfastBrick

final class EndpointResolverTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "EndpointResolverTests")!
        defaults.removePersistentDomain(forName: "EndpointResolverTests")
    }

    func testOrderingPrefersTailscaleDNSThenIPThenLAN() {
        let lan = BrickEndpoint(kind: .lan, host: "192.168.1.42", port: 8787)
        let ip = BrickEndpoint(kind: .tailscaleIP, host: "100.1.2.3", port: 8787)
        let dns = BrickEndpoint(kind: .tailscaleDNS, host: "brick.ts.net", port: 8787)

        let ordered = EndpointResolver.ordered([lan, ip, dns])

        XCTAssertEqual(ordered.map(\.kind), [.tailscaleDNS, .tailscaleIP, .lan])
    }

    func testResolvePicksFirstReachableCandidate() async throws {
        // Tailscale addresses answer, so LAN must never win.
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.host()?.hasPrefix("100.") ?? false
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        resolver.learn(from: BrickIdentity(
            deviceName: "Brick", version: "0.1", port: 8787,
            lanIP: "192.168.1.42", tailscaleIPs: ["100.1.2.3"], magicDNSName: ""
        ))

        let endpoint = try await resolver.resolve()

        XCTAssertEqual(endpoint.kind, .tailscaleIP)
        XCTAssertEqual(endpoint.host, "100.1.2.3")
    }

    func testResolveFallsBackToLANWhenTailscaleUnreachable() async throws {
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.host()?.hasPrefix("192.168.") ?? false
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        resolver.learn(from: BrickIdentity(
            deviceName: "Brick", version: "0.1", port: 8787,
            lanIP: "192.168.1.42", tailscaleIPs: ["100.1.2.3"],
            magicDNSName: "brick.ts.net"
        ))

        let endpoint = try await resolver.resolve()

        XCTAssertEqual(endpoint.kind, .lan)
    }

    func testResolveThrowsUnreachableWhenNothingAnswers() async {
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in false })
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
            return true
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
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in true })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        XCTAssertTrue(resolver.hasCandidates)

        resolver.forget()

        XCTAssertFalse(resolver.hasCandidates)
    }
}
