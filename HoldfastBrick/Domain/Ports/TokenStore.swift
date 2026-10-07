import Foundation

/// Where the pairing token lives. Keychain in production, memory in tests.
protocol TokenStore: AnyObject {
    var token: String? { get }
    func save(_ token: String)
    func clear()
}

/// In-memory store for tests, previews, and `-mockAPI` runs.
final class MemoryTokenStore: TokenStore {
    private(set) var token: String?

    func save(_ token: String) { self.token = token }
    func clear() { token = nil }
}
