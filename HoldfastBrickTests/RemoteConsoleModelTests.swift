import CryptoKit
import XCTest
@testable import HoldfastBrick

@MainActor
final class RemoteConsoleModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var api: ConsoleBrickAPIStub!
    private var keys: FakeSSHKeys!
    private var shell: FakeShellConnector!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "RemoteConsoleModelTests")!
        defaults.removePersistentDomain(forName: "RemoteConsoleModelTests")
        api = ConsoleBrickAPIStub()
        keys = FakeSSHKeys()
        shell = FakeShellConnector()
    }

    private func makeModel(lanHost: String = "10.0.0.230") -> RemoteConsoleModel {
        let endpoints = EndpointResolver(defaults: defaults, probe: { _ in
            .answered(certFingerprint: nil)
        })
        endpoints.adopt(lanHost: lanHost, port: 8787)
        return RemoteConsoleModel(
            api: api, keys: keys, shell: shell, endpoints: endpoints, defaults: defaults
        )
    }

    // MARK: - enable()

    func test_enable_success_installsKeyAndPersistsEnabled() async {
        let model = makeModel()
        XCTAssertFalse(model.isEnabled)

        await model.beginEnable()
        await model.confirmEnable()

        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(api.installedKeys, ["ssh-ed25519 FAKEBLOB holdfastbrick-app"])
        XCTAssertTrue(defaults.bool(forKey: "remoteConsoleEnabled"),
                      "the explainer should not reappear on the next visit")
    }

    func test_enable_requiresCodeShownOnBrick() async {
        let model = makeModel()
        await model.beginEnable()

        XCTAssertFalse(model.isEnabled)
        if case .awaitingCode = model.state {} else {
            XCTFail("expected awaitingCode, got \(model.state)")
        }
        XCTAssertEqual(api.confirmCodeRequests, 1)
        XCTAssertEqual(api.installedKeys, [], "no key may install before the code")
    }

    func test_enable_wrongCode_surfacesErrorAndStaysDisabled() async {
        let model = makeModel()
        api.installSSHKeyResult = .failure(
            BrickError.deviceError("Missing or wrong confirmation code.")
        )
        await model.beginEnable()
        model.confirmCode = "000000"
        await model.confirmEnable()

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.lastError, "Missing or wrong confirmation code.")
    }

    func test_enable_apiRejectsKey_surfacesMessageAndStaysDisabled() async {
        api.installSSHKeyResult = .success(BrickActionResult(ok: false, message: "Invalid key"))
        let model = makeModel()

        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.lastError, "Invalid key")
    }

    func test_enable_apiUnreachable_surfacesErrorAndStaysDisabled() async {
        api.installSSHKeyResult = .failure(BrickError.unreachable)
        let model = makeModel()

        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.lastError, BrickError.unreachable.errorDescription)
    }

    // MARK: - connect()

    func test_connect_whenEnabled_opensRootSessionAndConnects() async {
        let model = makeModel()
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()

        await model.connect()

        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(shell.hosts, ["10.0.0.230"])
        XCTAssertEqual(shell.usernames, ["root"])
    }

    func test_connect_bracketedIPv6Endpoint_passesNormalizedHostToShell() async {
        let model = makeModel(lanHost: "[fe80::1%25en0]")
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()

        await model.connect()

        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(shell.hosts, ["fe80::1%en0"])
    }

    func test_connect_beforeEnable_staysDisconnected() async {
        let model = makeModel()

        await model.connect()

        XCTAssertEqual(model.state, .disconnected)
        XCTAssertTrue(shell.hosts.isEmpty)
    }

    func test_connect_shellFailure_setsFailedState() async {
        shell.connectError = BrickError.unreachable
        let model = makeModel()
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()

        await model.connect()

        guard case let .failed(message) = model.state else {
            return XCTFail("expected .failed, got \(model.state)")
        }
        XCTAssertEqual(message, BrickError.unreachable.errorDescription)
    }

    func test_connect_whileAlreadyConnected_doesNotReconnect() async {
        let model = makeModel()
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()
        await model.connect()

        await model.connect()

        XCTAssertEqual(shell.hosts.count, 1)
    }

    // MARK: - run()

    func test_run_success_appendsCommandAndOutputToScrollback() async {
        shell.session.outputs["uname -a"] = "Linux holdfastbrick"
        let model = makeModel()
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()
        await model.connect()

        await model.run("uname -a")

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries[0].command, "uname -a")
        XCTAssertEqual(model.entries[0].output, "Linux holdfastbrick")
    }

    func test_run_sessionError_surfacesErrorInScrollback() async {
        shell.session.runError = BrickError.unreachable
        let model = makeModel()
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()
        await model.connect()

        await model.run("ls")

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertTrue(model.entries[0].output.hasPrefix("error:"))
    }

    func test_run_blankCommand_isIgnored() async {
        let model = makeModel()
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()
        await model.connect()

        await model.run("   ")

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(shell.session.commands.isEmpty)
    }

    func test_run_beforeConnect_isIgnored() async {
        let model = makeModel()
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()

        await model.run("ls")

        XCTAssertTrue(model.entries.isEmpty)
    }

    // MARK: - disconnect()

    func test_disconnect_closesSessionAndReturnsToDisconnected() async {
        let model = makeModel()
        await model.beginEnable()
        model.confirmCode = "123456"
        await model.confirmEnable()
        await model.connect()

        await model.disconnect()

        XCTAssertEqual(model.state, .disconnected)
        XCTAssertTrue(shell.session.closed)
    }
}

// MARK: - Fakes

private final class FakeSSHKeys: SSHKeyProviding {
    private let key = Curve25519.Signing.PrivateKey()

    func publicKeyOpenSSH(comment: String) throws -> String {
        "ssh-ed25519 FAKEBLOB \(comment)"
    }

    func privateKey() throws -> Curve25519.Signing.PrivateKey { key }
}

private final class FakeShellSession: RemoteShellSession {
    var outputs: [String: String] = [:]
    var runError: Error?
    private(set) var commands: [String] = []
    private(set) var closed = false

    func run(_ command: String) async throws -> String {
        commands.append(command)
        if let runError { throw runError }
        return outputs[command] ?? "ok"
    }

    func close() async { closed = true }
}

private final class FakeShellConnector: RemoteShellConnector {
    let session = FakeShellSession()
    var connectError: Error?
    private(set) var hosts: [String] = []
    private(set) var usernames: [String] = []

    func connect(host: String, username: String) async throws -> any RemoteShellSession {
        hosts.append(host)
        usernames.append(username)
        if let connectError { throw connectError }
        return session
    }
}

/// BrickAPI stub for console tests: only `installSSHKey` is expected to be
/// called; anything else is a test bug.
private final class ConsoleBrickAPIStub: BrickAPI {
    private(set) var confirmCodeRequests = 0
    var installSSHKeyResult: Result<BrickActionResult, Error> =
        .success(BrickActionResult(ok: true, message: "Key installed"))
    private(set) var installedKeys: [String] = []

    func requestSSHConfirmCode() async throws -> Date {
        confirmCodeRequests += 1
        return Date().addingTimeInterval(300)
    }
    func installSSHKey(publicKey: String, confirmCode: String?) async throws -> BrickActionResult {
        installedKeys.append(publicKey)
        return try installSSHKeyResult.get()
    }

    func removeSSHKey() async throws -> BrickActionResult { fatalError("unused") }

    func pair(code: String) async throws -> PairingGrant { fatalError("unused") }
    func identity() async throws -> BrickIdentity { fatalError("unused") }
    func overview() async throws -> BrickOverview { fatalError("unused") }
    func adBlockStats() async throws -> AdBlockStats { fatalError("unused") }
    func setAdBlocking(enabled: Bool) async throws -> BrickActionResult { fatalError("unused") }
    func queryLog(limit: Int, search: String?) async throws -> [QueryLogEntry] { fatalError("unused") }
    func blocklists() async throws -> [Blocklist] { fatalError("unused") }
    func addBlocklist(name: String, url: String) async throws -> BrickActionResult { fatalError("unused") }
    func removeBlocklist(url: String) async throws -> BrickActionResult { fatalError("unused") }
    func setDomainRule(domain: String, action: DomainRuleAction) async throws -> BrickActionResult { fatalError("unused") }
    func dnsStats() async throws -> DNSStats { fatalError("unused") }
    func flushDNSCache() async throws -> BrickActionResult { fatalError("unused") }
    func restartPrivateDNS() async throws -> BrickActionResult { fatalError("unused") }
    func remoteAccessStatus() async throws -> RemoteAccessStatus { fatalError("unused") }
    func setRemoteAccess(enabled: Bool) async throws -> BrickActionResult { fatalError("unused") }
    func setCloudFiltering(enabled: Bool) async throws -> BrickActionResult { fatalError("unused") }
    func networkDevices() async throws -> [NetworkDevice] { fatalError("unused") }
    func dhcpStatus() async throws -> DHCPStatus { fatalError("unused") }
    func dhcpCheck() async throws -> DHCPCheck { fatalError("unused") }
    func enableDHCP(force: Bool) async throws -> DHCPEnableResult { fatalError("unused") }
    func disableDHCP() async throws -> BrickActionResult { fatalError("unused") }
    func routerInfo() async throws -> RouterInfo { fatalError("unused") }
    func deviceHealth() async throws -> DeviceHealth { fatalError("unused") }
    func rebootDevice() async throws -> BrickActionResult { fatalError("unused") }
    func startUpdate() async throws -> BrickActionResult { fatalError("unused") }
    func updateStatus() async throws -> UpdateStatus { fatalError("unused") }
}
