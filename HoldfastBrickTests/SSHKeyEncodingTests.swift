import XCTest
@testable import HoldfastBrick

final class SSHKeyEncodingTests: XCTestCase {
    // 32-byte fixed key: bytes 0x00, 0x01, ... 0x1f.
    private let sequentialKey = Data(0 ..< 32)
    // 32 bytes of 0xAB.
    private let repeatedKey = Data(repeating: 0xAB, count: 32)

    func test_openSSHPublicKey_fixedSequentialKey_producesExactExpectedLine() {
        let line = SSHKeyEncoding.openSSHPublicKey(
            rawPublicKey: sequentialKey, comment: "holdfastbrick-app"
        )
        // Blob = uint32(11) + "ssh-ed25519" + uint32(32) + raw key, base64'd.
        XCTAssertEqual(
            line,
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f holdfastbrick-app"
        )
    }

    func test_openSSHPublicKey_fixedRepeatedKey_producesExactExpectedBase64() {
        let line = SSHKeyEncoding.openSSHPublicKey(rawPublicKey: repeatedKey, comment: "c")
        XCTAssertEqual(
            line,
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKurq6urq6urq6urq6urq6urq6urq6urq6urq6urq6ur c"
        )
    }

    func test_openSSHPublicKey_anyKey_blobIsExactly51BytesInWireFormat() throws {
        let line = SSHKeyEncoding.openSSHPublicKey(
            rawPublicKey: sequentialKey, comment: "holdfastbrick-app"
        )
        let parts = line.split(separator: " ")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "ssh-ed25519")
        XCTAssertEqual(parts[2], "holdfastbrick-app")

        let blob = try XCTUnwrap(Data(base64Encoded: String(parts[1])))
        XCTAssertEqual(blob.count, 51, "the brick strictly validates the 51-byte wire format")
        // uint32 big-endian length 11, then "ssh-ed25519".
        XCTAssertEqual(Array(blob.prefix(4)), [0x00, 0x00, 0x00, 0x0B])
        XCTAssertEqual(Data(blob[4 ..< 15]), Data("ssh-ed25519".utf8))
        // uint32 big-endian length 32, then the raw key.
        XCTAssertEqual(Array(blob[15 ..< 19]), [0x00, 0x00, 0x00, 0x20])
        XCTAssertEqual(Data(blob[19 ..< 51]), sequentialKey)
    }

    // MARK: - Host normalization

    func test_sshHost_bracketedIPv6WithEncodedZone_stripsBracketsAndDecodesZone() {
        XCTAssertEqual(RemoteConsoleModel.sshHost(from: "[fe80::1%25en0]"), "fe80::1%en0")
    }

    func test_sshHost_bracketedIPv6_stripsBrackets() {
        XCTAssertEqual(RemoteConsoleModel.sshHost(from: "[2001:db8::1]"), "2001:db8::1")
    }

    func test_sshHost_bareIPv4_isUnchanged() {
        XCTAssertEqual(RemoteConsoleModel.sshHost(from: "10.0.0.230"), "10.0.0.230")
    }

    func test_sshHost_hostname_isUnchanged() {
        XCTAssertEqual(
            RemoteConsoleModel.sshHost(from: "holdfastbrick.tailnet-demo.ts.net"),
            "holdfastbrick.tailnet-demo.ts.net"
        )
    }
}
