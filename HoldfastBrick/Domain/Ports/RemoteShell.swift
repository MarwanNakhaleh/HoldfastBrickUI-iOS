import CryptoKit
import Foundation

/// The device's SSH identity, as far as features need to know: an OpenSSH
/// public-key line to hand to the brick, and the private key for the
/// transport layer to authenticate with. Key generation and custody live
/// behind this port (Keychain in production, memory in tests).
protocol SSHKeyProviding: AnyObject {
    /// `ssh-ed25519 <base64-blob> <comment>` — the exact line the brick's
    /// `/api/v1/system/ssh-key` endpoint validates and installs.
    func publicKeyOpenSSH(comment: String) throws -> String
    /// The signing key backing that public key.
    func privateKey() throws -> Curve25519.Signing.PrivateKey
}

/// An open shell on the brick. One session per console visit.
protocol RemoteShellSession: AnyObject {
    /// Runs one command and returns its combined stdout+stderr.
    func run(_ command: String) async throws -> String
    func close() async
}

/// Opens SSH sessions. Citadel in production, a canned fake in tests and
/// `-mockAPI` runs — the console model never touches a socket directly.
protocol RemoteShellConnector: AnyObject {
    func connect(host: String, username: String) async throws -> any RemoteShellSession
}
