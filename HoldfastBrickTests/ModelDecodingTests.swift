import XCTest
@testable import HoldfastBrick

/// Pins the wire contract with HoldfastBrickAPI: these JSON fixtures are the
/// exact shapes the Pi returns. If decoding breaks here, the app would break
/// against the real device.
final class ModelDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testOverviewDecoding() throws {
        let overview = try decode(BrickOverview.self, """
        {"device_name": "Holdfast Brick", "protected": true,
         "services": [{"id": "adguard", "name": "Ad Blocking", "running": true,
                       "installed": true, "detail": "protecting"}]}
        """)
        XCTAssertEqual(overview.deviceName, "Holdfast Brick")
        XCTAssertTrue(overview.protected)
        XCTAssertEqual(overview.services.first?.name, "Ad Blocking")
    }

    func testIdentityDecoding() throws {
        let identity = try decode(BrickIdentity.self, """
        {"device_name": "Holdfast Brick", "version": "0.1.0", "port": 8787,
         "lan_ip": "192.168.1.42", "tailscale_ips": ["100.101.102.103"],
         "magicdns_name": "holdfastbrick.tail1234.ts.net"}
        """)
        XCTAssertEqual(identity.tailscaleIPs, ["100.101.102.103"])
        XCTAssertEqual(identity.magicDNSName, "holdfastbrick.tail1234.ts.net")
        XCTAssertEqual(identity.port, 8787)
    }

    func testQueryLogDecoding() throws {
        let page = try decode(QueryLogPage.self, """
        {"entries": [{"domain": "doubleclick.net", "client": "192.168.1.10",
                      "time": "2026-07-28T18:59:00Z", "blocked": true,
                      "reason": "FilteredBlackList"}]}
        """)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertTrue(page.entries[0].blocked)
        XCTAssertEqual(page.entries[0].domain, "doubleclick.net")
    }

    func testBlocklistDecoding() throws {
        let page = try decode(BlocklistPage.self, """
        {"blocklists": [{"id": 1, "name": "OISD", "url": "https://abp.oisd.nl/basic/",
                         "enabled": true, "rules_count": 212340}]}
        """)
        XCTAssertEqual(page.blocklists.first?.rulesCount, 212_340)
    }

    func testDeviceHealthDecodingWithNulls() throws {
        // A brick that can't read its temperature must still decode.
        let health = try decode(DeviceHealth.self, """
        {"hostname": "holdfastbrick", "uptime": "3 weeks", "cpu_temp_celsius": null,
         "memory_total_mb": null, "memory_used_mb": null,
         "disk_used_percent": null, "dietpi_version": null}
        """)
        XCTAssertNil(health.cpuTempCelsius)
        XCTAssertEqual(health.hostname, "holdfastbrick")
    }

    func testPairingGrantDecoding() throws {
        let grant = try decode(PairingGrant.self, """
        {"token": "abc123", "device_name": "Holdfast Brick"}
        """)
        XCTAssertEqual(grant.token, "abc123")
    }

    // MARK: - Whole-Home Protection (DHCP)

    func test_dhcpStatus_contractPayload_decodesAllFields() throws {
        let status = try decode(DHCPStatus.self, """
        {"enabled": true, "interface": "eth0", "gateway": "192.168.1.1",
         "range_start": "192.168.1.100", "range_end": "192.168.1.250",
         "lease_count": 7}
        """)
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.interface, "eth0")
        XCTAssertEqual(status.gateway, "192.168.1.1")
        XCTAssertEqual(status.rangeStart, "192.168.1.100")
        XCTAssertEqual(status.rangeEnd, "192.168.1.250")
        XCTAssertEqual(status.leaseCount, 7)
    }

    func test_dhcpCheck_contractPayload_decodesProbeResults() throws {
        let check = try decode(DHCPCheck.self, """
        {"interface": "eth0", "pi_ip": "192.168.1.42", "gateway_ip": "192.168.1.1",
         "other_dhcp": "yes", "other_dhcp_error": "", "static_ip": "no"}
        """)
        XCTAssertEqual(check.otherDHCP, .yes)
        XCTAssertEqual(check.staticIP, .no)
        XCTAssertEqual(check.piIP, "192.168.1.42")
        XCTAssertEqual(check.gatewayIP, "192.168.1.1")
        XCTAssertEqual(check.interface, "eth0")
    }

    func test_dhcpCheck_errorAndUnrecognizedValues_decodeTolerantly() throws {
        let check = try decode(DHCPCheck.self, """
        {"interface": "eth0", "pi_ip": "192.168.1.42", "gateway_ip": "192.168.1.1",
         "other_dhcp": "error", "other_dhcp_error": "probe timed out",
         "static_ip": "something-new"}
        """)
        XCTAssertEqual(check.otherDHCP, .error)
        XCTAssertEqual(check.otherDHCPError, "probe timed out")
        XCTAssertEqual(check.staticIP, .unknown,
                       "unrecognized wire values must fall back to .unknown")
    }

    func test_dhcpEnableResult_contractPayload_decodesNeedsReboot() throws {
        let result = try decode(DHCPEnableResult.self, """
        {"ok": true, "message": "DHCP enabled", "needs_reboot": true}
        """)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "DHCP enabled")
        XCTAssertTrue(result.needsReboot)
    }

    func test_routerInfo_contractPayload_decodesVendorKey() throws {
        let router = try decode(RouterInfo.self, """
        {"gateway_ip": "10.0.0.1", "gateway_mac": "aa:bb:cc:dd:ee:ff",
         "vendor": "Xfinity", "vendor_key": "xfinity", "portal_url": "http://10.0.0.1"}
        """)
        XCTAssertEqual(router.vendorKey, .xfinity)
        XCTAssertEqual(router.vendor, "Xfinity")
        XCTAssertEqual(router.gatewayIP, "10.0.0.1")
        XCTAssertEqual(router.gatewayMAC, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(router.portalURL, "http://10.0.0.1")
    }

    func test_routerInfo_unrecognizedVendorKey_decodesAsUnknown() throws {
        let router = try decode(RouterInfo.self, """
        {"gateway_ip": "10.0.0.1", "gateway_mac": "aa:bb:cc:dd:ee:ff",
         "vendor": "SomeNewRouter", "vendor_key": "linksys", "portal_url": "http://10.0.0.1"}
        """)
        XCTAssertEqual(router.vendorKey, .unknown)
        XCTAssertEqual(router.vendor, "SomeNewRouter",
                       "the display name must survive even when the key is unrecognized")
    }

    // MARK: - System Update

    func test_updateStatus_contractPayload_decodesRunning() throws {
        XCTAssertTrue(try decode(UpdateStatus.self, #"{"running": true}"#).running)
        XCTAssertFalse(try decode(UpdateStatus.self, #"{"running": false}"#).running)
    }
}
