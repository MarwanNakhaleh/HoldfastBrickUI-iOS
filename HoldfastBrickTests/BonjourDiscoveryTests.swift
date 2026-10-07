import Network
import XCTest
@testable import HoldfastBrick

final class BonjourDiscoveryTests: XCTestCase {
    func test_hostString_ipv4_returnsBareAddress() {
        let host = NWEndpoint.Host.ipv4(IPv4Address("192.168.1.42")!)
        XCTAssertEqual(BonjourDiscovery.hostString(host), "192.168.1.42")
        XCTAssertNotNil(URL(string: "http://\(BonjourDiscovery.hostString(host)):8787"))
    }

    func test_hostString_ipv4WithZone_stripsZone() throws {
        // Network.framework attaches the resolving interface to addresses it
        // hands back ("10.0.0.230%en0"); the bare "%" makes URL(string:)
        // reject the URL, so the brick looked unreachable (real-device bug,
        // 2026-07-28).
        guard let address = IPv4Address("10.0.0.230%en0") else {
            throw XCTSkip("no en0 interface in this test environment")
        }
        let hostString = BonjourDiscovery.hostString(NWEndpoint.Host.ipv4(address))
        XCTAssertEqual(hostString, "10.0.0.230")
        XCTAssertNotNil(URL(string: "http://\(hostString):8787"))
    }

    func test_hostString_ipv6_bracketsAddress() {
        let host = NWEndpoint.Host.ipv6(IPv6Address("2001:db8::1")!)
        XCTAssertEqual(BonjourDiscovery.hostString(host), "[2001:db8::1]")
        XCTAssertNotNil(URL(string: "http://\(BonjourDiscovery.hostString(host)):8787"))
    }

    func test_hostString_ipv6LinkLocalWithZone_formsValidURL() throws {
        // fe80::1%en0 — the raw zone suffix made URL(string:) reject the
        // whole URL before the fix, so the brick looked unreachable.
        guard let address = IPv6Address("fe80::1%en0") else {
            throw XCTSkip("no en0 interface in this test environment")
        }
        let hostString = BonjourDiscovery.hostString(NWEndpoint.Host.ipv6(address))
        XCTAssertFalse(hostString.contains("%en0"),
                       "zone ID must not appear raw in \(hostString)")
        XCTAssertNotNil(URL(string: "http://\(hostString):8787"),
                        "host string must form a valid URL: \(hostString)")
    }

    func test_hostString_name_passesThrough() {
        let host = NWEndpoint.Host.name("brick.local", nil)
        XCTAssertEqual(BonjourDiscovery.hostString(host), "brick.local")
    }
}
