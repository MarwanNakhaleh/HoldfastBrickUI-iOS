import XCTest
@testable import HoldfastBrick

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(api: BrickAPI = MockBrickAPI()) -> (AppModel, MemoryTokenStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "AppModelTests")!
        defaults.removePersistentDomain(forName: "AppModelTests")
        let tokens = MemoryTokenStore()
        let model = AppModel(
            api: api,
            tokens: tokens,
            endpoints: EndpointResolver(defaults: defaults, probe: { _ in
                .answered(certFingerprint: MockBrickAPI.certFingerprint)
            }),
            defaults: defaults
        )
        return (model, tokens, defaults)
    }

    private var demoBrick: DiscoveredBrick {
        DiscoveredBrick(id: "demo", name: "Demo", host: "127.0.0.1", port: 8787)
    }

    func testStartsUnpairedWithNoStoredSession() {
        let (model, _, _) = makeModel()
        XCTAssertEqual(model.phase, .needsDevice)
    }

    func testSuccessfulPairingConnectsAndStoresToken() async throws {
        let (model, tokens, _) = makeModel()
        model.startPairing(with: demoBrick)

        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)

        XCTAssertEqual(model.phase, .connected)
        XCTAssertNotNil(tokens.token)
        XCTAssertNotNil(model.overview, "pairing should immediately load the dashboard")
    }

    func testPairingSurfacesBrickIDFromCertificateFingerprint() async throws {
        let (model, _, _) = makeModel()

        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)

        XCTAssertEqual(model.brickID, "A7A7…A7A7")
    }

    func testWrongCodeSurfacesFriendlyErrorAndStaysUnpaired() async {
        let (model, tokens, _) = makeModel()
        model.startPairing(with: demoBrick)

        do {
            try await model.completePairing(brick: demoBrick, code: "000000")
            XCTFail("expected pairing to fail")
        } catch let BrickError.pairingRejected(message) {
            XCTAssertTrue(message.lowercased().contains("code"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(tokens.token)
        XCTAssertNotEqual(model.phase, .connected)
    }

    func testForgetDeviceClearsSession() async throws {
        let (model, tokens, _) = makeModel()
        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)

        await model.forgetDevice()

        XCTAssertEqual(model.phase, .needsDevice)
        XCTAssertNil(tokens.token)
        XCTAssertNil(model.overview)
    }

    func testForgetDeviceRemovesSSHKeyAndClearsConsoleFlagAndTOFUPins() async throws {
        let api = RecordingBrickAPI()
        let (model, tokens, defaults) = makeModel(api: api)
        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)
        defaults.set(true, forKey: "remoteConsoleEnabled")
        defaults.set("AAAA", forKey: "sshTrustedHostKey:192.168.1.42")
        defaults.set("BBBB", forKey: "sshTrustedHostKey:holdfastbrick.local")

        await model.forgetDevice()

        XCTAssertEqual(api.removeSSHKeyCalls, 1, "unpair must ask the brick to drop our key")
        XCTAssertFalse(defaults.bool(forKey: "remoteConsoleEnabled"))
        XCTAssertNil(defaults.object(forKey: "sshTrustedHostKey:192.168.1.42"))
        XCTAssertNil(defaults.object(forKey: "sshTrustedHostKey:holdfastbrick.local"))
        XCTAssertNil(tokens.token)
        XCTAssertNil(model.overview)
        XCTAssertEqual(model.phase, .needsDevice)
    }

    func testForgetDeviceSurvivesRemoveSSHKeyFailure() async throws {
        let api = FailingRemoveSSHKeyAPI()
        let (model, tokens, defaults) = makeModel(api: api)
        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)
        defaults.set("AAAA", forKey: "sshTrustedHostKey:192.168.1.42")

        await model.forgetDevice()

        XCTAssertEqual(api.removeSSHKeyCalls, 1)
        XCTAssertEqual(model.phase, .needsDevice, "unpair must complete even when the brick is unreachable")
        XCTAssertNil(tokens.token)
        XCTAssertNil(defaults.object(forKey: "sshTrustedHostKey:192.168.1.42"))
    }

    func testRefreshLoadsOverview() async throws {
        let (model, _, _) = makeModel()
        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)

        await model.refresh()

        XCTAssertEqual(model.overview?.services.isEmpty, false)
        XCTAssertNil(model.lastError)
    }
}

/// Records unpair calls; everything else delegates to the mock brick.
private class RecordingBrickAPI: BrickAPI {
    let inner = MockBrickAPI()
    var removeSSHKeyCalls = 0

    func removeSSHKey() async throws -> BrickActionResult {
        removeSSHKeyCalls += 1
        return BrickActionResult(ok: true, message: "Key removed")
    }

    func pair(code: String) async throws -> PairingGrant { try await inner.pair(code: code) }
    func identity() async throws -> BrickIdentity { try await inner.identity() }
    func overview() async throws -> BrickOverview { try await inner.overview() }
    func adBlockStats() async throws -> AdBlockStats { try await inner.adBlockStats() }
    func setAdBlocking(enabled: Bool) async throws -> BrickActionResult {
        try await inner.setAdBlocking(enabled: enabled)
    }
    func queryLog(limit: Int, search: String?) async throws -> [QueryLogEntry] {
        try await inner.queryLog(limit: limit, search: search)
    }
    func blocklists() async throws -> [Blocklist] { try await inner.blocklists() }
    func addBlocklist(name: String, url: String) async throws -> BrickActionResult {
        try await inner.addBlocklist(name: name, url: url)
    }
    func removeBlocklist(url: String) async throws -> BrickActionResult {
        try await inner.removeBlocklist(url: url)
    }
    func setDomainRule(domain: String, action: DomainRuleAction) async throws -> BrickActionResult {
        try await inner.setDomainRule(domain: domain, action: action)
    }
    func dnsStats() async throws -> DNSStats { try await inner.dnsStats() }
    func flushDNSCache() async throws -> BrickActionResult { try await inner.flushDNSCache() }
    func restartPrivateDNS() async throws -> BrickActionResult {
        try await inner.restartPrivateDNS()
    }
    func remoteAccessStatus() async throws -> RemoteAccessStatus {
        try await inner.remoteAccessStatus()
    }
    func setRemoteAccess(enabled: Bool) async throws -> BrickActionResult {
        try await inner.setRemoteAccess(enabled: enabled)
    }
    func setCloudFiltering(enabled: Bool) async throws -> BrickActionResult {
        try await inner.setCloudFiltering(enabled: enabled)
    }
    func networkDevices() async throws -> [NetworkDevice] { try await inner.networkDevices() }
    func dhcpStatus() async throws -> DHCPStatus { try await inner.dhcpStatus() }
    func dhcpCheck() async throws -> DHCPCheck { try await inner.dhcpCheck() }
    func enableDHCP(force: Bool) async throws -> DHCPEnableResult {
        try await inner.enableDHCP(force: force)
    }
    func disableDHCP() async throws -> BrickActionResult { try await inner.disableDHCP() }
    func routerInfo() async throws -> RouterInfo { try await inner.routerInfo() }
    func requestSSHConfirmCode() async throws -> Date {
        try await inner.requestSSHConfirmCode()
    }
    func installSSHKey(publicKey: String, confirmCode: String?) async throws -> BrickActionResult {
        try await inner.installSSHKey(publicKey: publicKey, confirmCode: confirmCode)
    }
    func deviceHealth() async throws -> DeviceHealth { try await inner.deviceHealth() }
    func rebootDevice() async throws -> BrickActionResult { try await inner.rebootDevice() }
    func startUpdate() async throws -> BrickActionResult { try await inner.startUpdate() }
    func updateStatus() async throws -> UpdateStatus { try await inner.updateStatus() }
}

/// Simulates an unreachable brick during unpair: the remote cleanup must
/// fail without blocking the local cleanup.
private final class FailingRemoveSSHKeyAPI: RecordingBrickAPI {
    override func removeSSHKey() async throws -> BrickActionResult {
        removeSSHKeyCalls += 1
        throw BrickError.unreachable
    }
}
