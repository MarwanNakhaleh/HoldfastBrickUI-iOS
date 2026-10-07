import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Trust-on-first-use host key policy: the first key a host ever presents is
/// remembered (UserDefaults, keyed by host) and any later change is rejected —
/// same contract as OpenSSH's known_hosts.
final class TrustOnFirstUseHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    struct HostKeyChanged: LocalizedError {
        var errorDescription: String? {
            "The device's SSH identity changed since this phone first trusted it. "
                + "If you reinstalled the brick this is expected — forget and re-pair "
                + "the device to trust it again."
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(host: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storageKey = "sshTrustedHostKey:\(host)"
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let presented = Data(buffer.readableBytesView).base64EncodedString()

        if let trusted = defaults.string(forKey: storageKey) {
            if trusted == presented {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyChanged())
            }
        } else {
            defaults.set(presented, forKey: storageKey)
            validationCompletePromise.succeed(())
        }
    }
}

/// Citadel-backed implementation of the shell port: ed25519 key auth as the
/// given user, TOFU host key pinning, one exec channel per command.
final class CitadelShellConnector: RemoteShellConnector {
    private let keys: any SSHKeyProviding

    init(keys: any SSHKeyProviding) {
        self.keys = keys
    }

    func connect(host: String, username: String) async throws -> any RemoteShellSession {
        let key = try keys.privateKey()
        let client = try await SSHClient.connect(
            host: host,
            port: 22,
            authenticationMethod: .ed25519(username: username, privateKey: key),
            hostKeyValidator: .custom(TrustOnFirstUseHostKeyValidator(host: host)),
            reconnect: .never
        )
        return CitadelShellSession(client: client)
    }
}

final class CitadelShellSession: RemoteShellSession {
    private let client: SSHClient

    init(client: SSHClient) {
        self.client = client
    }

    func run(_ command: String) async throws -> String {
        // mergeStreams folds stderr into the output, so failures read the
        // same way they would in a terminal.
        let buffer = try await client.executeCommand(command, mergeStreams: true)
        return String(buffer: buffer)
    }

    func close() async {
        try? await client.close()
    }
}
