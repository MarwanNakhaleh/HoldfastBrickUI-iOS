import XCTest
@testable import HoldfastBrick

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel() -> (AppModel, MemoryTokenStore) {
        let defaults = UserDefaults(suiteName: "AppModelTests")!
        defaults.removePersistentDomain(forName: "AppModelTests")
        let tokens = MemoryTokenStore()
        let model = AppModel(
            api: MockBrickAPI(),
            tokens: tokens,
            endpoints: EndpointResolver(defaults: defaults, probe: { _ in true })
        )
        return (model, tokens)
    }

    private var demoBrick: DiscoveredBrick {
        DiscoveredBrick(id: "demo", name: "Demo", host: "127.0.0.1", port: 8787)
    }

    func testStartsUnpairedWithNoStoredSession() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.phase, .needsDevice)
    }

    func testSuccessfulPairingConnectsAndStoresToken() async throws {
        let (model, tokens) = makeModel()
        model.startPairing(with: demoBrick)

        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)

        XCTAssertEqual(model.phase, .connected)
        XCTAssertNotNil(tokens.token)
        XCTAssertNotNil(model.overview, "pairing should immediately load the dashboard")
    }

    func testWrongCodeSurfacesFriendlyErrorAndStaysUnpaired() async {
        let (model, tokens) = makeModel()
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
        let (model, tokens) = makeModel()
        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)

        model.forgetDevice()

        XCTAssertEqual(model.phase, .needsDevice)
        XCTAssertNil(tokens.token)
        XCTAssertNil(model.overview)
    }

    func testRefreshLoadsOverview() async throws {
        let (model, _) = makeModel()
        try await model.completePairing(brick: demoBrick, code: MockBrickAPI.pairingCode)

        await model.refresh()

        XCTAssertEqual(model.overview?.services.isEmpty, false)
        XCTAssertNil(model.lastError)
    }
}
