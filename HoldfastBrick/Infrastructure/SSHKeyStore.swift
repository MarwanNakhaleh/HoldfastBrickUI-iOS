import CryptoKit
import Foundation
import Security

/// Pure OpenSSH encoding, separated from key custody so it can be unit-tested
/// against fixed key material.
enum SSHKeyEncoding {
    /// `ssh-ed25519 <base64-blob> <comment>` where the blob is the exact
    /// 51-byte ed25519 wire format the brick validates: a uint32-length-prefixed
    /// "ssh-ed25519" string followed by the uint32-length-prefixed 32-byte raw key.
    static func openSSHPublicKey(rawPublicKey: Data, comment: String) -> String {
        var blob = Data()
        appendSSHString(Data("ssh-ed25519".utf8), to: &blob)
        appendSSHString(rawPublicKey, to: &blob)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    private static func appendSSHString(_ bytes: Data, to blob: inout Data) {
        let length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: length) { blob.append(contentsOf: $0) }
        blob.append(bytes)
    }
}

/// Keychain-backed home for the device's SSH keypair. The key is generated
/// on first use and never leaves the Keychain except as its raw seed for
/// signing; only the public half is ever sent to the brick.
final class SSHKeyStore: SSHKeyProviding {
    private let service = "com.marwannakhaleh.holdfastbrick"
    private let account = "sshPrivateKey"

    enum KeyStoreError: LocalizedError {
        case keychainRead(OSStatus)
        case keychainWrite(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .keychainRead(status): return "Couldn't read the SSH key (Keychain error \(status))."
            case let .keychainWrite(status): return "Couldn't save the SSH key (Keychain error \(status))."
            }
        }
    }

    /// The device's private key, generated on first use. Fails loudly on any
    /// Keychain error other than "not found" — silently regenerating would
    /// orphan the public key already installed on the brick.
    func privateKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try storedKeyData() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        try store(key.rawRepresentation)
        return key
    }

    func publicKeyOpenSSH(comment: String) throws -> String {
        let key = try privateKey()
        return SSHKeyEncoding.openSSHPublicKey(
            rawPublicKey: key.publicKey.rawRepresentation, comment: comment
        )
    }

    // MARK: - Keychain

    private func storedKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyStoreError.keychainRead(status)
        }
        return data
    }

    private func store(_ data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainWrite(status)
        }
    }
}
