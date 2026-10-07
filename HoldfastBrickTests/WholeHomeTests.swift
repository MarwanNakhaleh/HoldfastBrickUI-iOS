import XCTest
@testable import HoldfastBrick

/// Pure logic for the Whole-Home Protection flow (vendor instructions, state
/// derivation) plus the full guided flow driven against the deterministic mock.
@MainActor
final class WholeHomeTests: XCTestCase {
    private func fixtureCheck(otherDHCP: DHCPProbeResult) -> DHCPCheck {
        DHCPCheck(
            interface: "eth0", piIP: "192.168.1.42", gatewayIP: "192.168.1.1",
            otherDHCP: otherDHCP,
            otherDHCPError: otherDHCP == .error ? "probe failed" : "",
            staticIP: .yes
        )
    }

    private var fixtureRouter: RouterInfo {
        RouterInfo(gatewayIP: "192.168.1.1", gatewayMAC: "aa:bb:cc:dd:ee:ff",
                   vendor: "Xfinity", vendorKey: .xfinity, portalURL: "http://10.0.0.1")
    }

    // MARK: - Vendor instructions

    func test_routerInstructions_everyVendorKey_returnsNonEmptySteps() {
        for vendor in RouterVendor.allCases {
            let steps = RouterInstructions.steps(for: vendor)
            XCTAssertFalse(steps.isEmpty, "no instructions for \(vendor)")
            XCTAssertTrue(steps.allSatisfy { !$0.isEmpty },
                          "empty instruction step for \(vendor)")
        }
    }

    // MARK: - State derivation

    func test_stateDerivation_otherDHCPNo_returnsReady() {
        let state = WholeHomeModel.state(afterCheck: fixtureCheck(otherDHCP: .no),
                                         router: fixtureRouter)
        XCTAssertEqual(state, .ready)
    }

    func test_stateDerivation_otherDHCPYes_returnsBlocked() {
        let check = fixtureCheck(otherDHCP: .yes)
        let state = WholeHomeModel.state(afterCheck: check, router: fixtureRouter)
        XCTAssertEqual(state, .blocked(check: check, router: fixtureRouter))
    }

    func test_stateDerivation_errorOrUnknownProbe_returnsBlocked() {
        for probe in [DHCPProbeResult.error, .unknown] {
            let check = fixtureCheck(otherDHCP: probe)
            let state = WholeHomeModel.state(afterCheck: check, router: nil)
            XCTAssertEqual(state, .blocked(check: check, router: nil),
                           "an inconclusive probe (\(probe)) must not unlock enabling")
        }
    }

    // MARK: - Guided flow against the mock brick

    func test_load_whenDHCPOff_landsOnIntro() async {
        let model = WholeHomeModel(api: MockBrickAPI())
        await model.load()
        XCTAssertEqual(model.state, .intro)
        XCTAssertNil(model.errorMessage)
    }

    func test_check_firstRunFindsRouterDHCP_showsBlockerThenReadyOnRecheck() async {
        let model = WholeHomeModel(api: MockBrickAPI())
        await model.load()

        await model.check()
        guard case let .blocked(check, router) = model.state else {
            return XCTFail("expected the blocker after the first probe, got \(model.state)")
        }
        XCTAssertEqual(check.otherDHCP, .yes)
        XCTAssertEqual(router?.vendorKey, .xfinity)

        await model.check() // "after the portal visit"
        XCTAssertEqual(model.state, .ready)
    }

    func test_enable_afterReadyCheck_reachesEnabledState() async {
        let model = WholeHomeModel(api: MockBrickAPI())
        await model.load()
        await model.check() // blocked
        await model.check() // ready

        await model.enable()

        guard case let .enabled(status) = model.state else {
            return XCTFail("expected enabled state, got \(model.state)")
        }
        XCTAssertTrue(status.enabled)
        XCTAssertGreaterThan(status.leaseCount, 0)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.needsReboot)
    }

    func test_disable_fromEnabledState_returnsToIntro() async {
        let model = WholeHomeModel(api: MockBrickAPI())
        await model.load()
        await model.check()
        await model.check()
        await model.enable()

        await model.disable()

        XCTAssertEqual(model.state, .intro)
        XCTAssertNil(model.errorMessage)
    }

    func test_load_whenBrickAlreadyManagesDHCP_showsEnabledState() async throws {
        let api = MockBrickAPI()
        _ = try await api.enableDHCP(force: false)

        let model = WholeHomeModel(api: api)
        await model.load()

        guard case .enabled = model.state else {
            return XCTFail("expected enabled state on appear, got \(model.state)")
        }
    }
}
