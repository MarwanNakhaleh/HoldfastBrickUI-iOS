import Foundation
import Observation

/// Power-user escape hatch: an SSH session to the brick as root. The model
/// owns the two-step lifecycle — enable (install this phone's public key via
/// the paired API) and connect/run (SSH through the shell port).
@Observable
@MainActor
final class RemoteConsoleModel {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// One command and what it printed, in scrollback order.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let command: String
        var output: String
    }

    static let username = "root"
    static let keyComment = "holdfastbrick-app"
    private static let enabledKey = "remoteConsoleEnabled"

    private(set) var state: State = .disconnected
    private(set) var entries: [Entry] = []
    private(set) var isEnabled: Bool
    private(set) var isEnabling = false
    private(set) var isRunning = false
    var lastError: String?

    private let api: BrickAPI
    private let keys: any SSHKeyProviding
    private let shell: any RemoteShellConnector
    private let endpoints: EndpointResolver
    private let defaults: UserDefaults
    private var session: (any RemoteShellSession)?

    init(
        api: BrickAPI,
        keys: any SSHKeyProviding,
        shell: any RemoteShellConnector,
        endpoints: EndpointResolver,
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.keys = keys
        self.shell = shell
        self.endpoints = endpoints
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// SSH wants a bare host: the resolver's `host` may be a bracketed IPv6
    /// with a percent-encoded zone ("[fe80::1%25en0]") — strip the brackets
    /// and decode %25 back to %.
    nonisolated static func sshHost(from host: String) -> String {
        var bare = host
        if bare.hasPrefix("["), bare.hasSuffix("]") {
            bare = String(bare.dropFirst().dropLast())
        }
        return bare.replacingOccurrences(of: "%25", with: "%")
    }

    /// Ensure the device keypair exists and install its public half on the
    /// brick through the paired API.
    func enable() async {
        guard !isEnabling else { return }
        isEnabling = true
        lastError = nil
        defer { isEnabling = false }
        do {
            let publicKey = try keys.publicKeyOpenSSH(comment: Self.keyComment)
            let result = try await api.installSSHKey(publicKey: publicKey)
            guard result.ok else {
                lastError = result.message
                return
            }
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Resolve the brick's current address and open an SSH session to it.
    func connect() async {
        guard isEnabled, state != .connecting, state != .connected else { return }
        state = .connecting
        do {
            // Re-post the public key first (idempotent): the brick pins SSH
            // access to the address that installed the key, so this moves
            // the whitelist along whenever this device's IP has changed.
            if let publicKey = try? keys.publicKeyOpenSSH(comment: Self.keyComment) {
                _ = try? await api.installSSHKey(publicKey: publicKey)
            }
            let endpoint = try await endpoints.resolve()
            let host = Self.sshHost(from: endpoint.host)
            session = try await shell.connect(host: host, username: Self.username)
            state = .connected
        } catch {
            session = nil
            state = .failed(error.localizedDescription)
        }
    }

    /// Commands longer than this get cut off — an interactive console can't
    /// host `tail -f`-style processes, and without a deadline one of those
    /// would wedge the session forever.
    private static let commandTimeout: Duration = .seconds(60)
    /// Scrollback cap, so a chatty session can't grow memory without bound.
    private static let maxScrollback = 200

    private struct CommandTimedOut: Error {}

    /// Run one command, appending it and its output to the scrollback.
    func run(_ command: String) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        if entries.count >= Self.maxScrollback {
            entries.removeFirst(entries.count - Self.maxScrollback + 1)
        }
        let index = entries.count
        entries.append(Entry(id: UUID(), command: trimmed, output: ""))
        do {
            let output = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await session.run(trimmed) }
                group.addTask {
                    try await Task.sleep(for: Self.commandTimeout)
                    throw CommandTimedOut()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            entries[index].output = output.trimmingCharacters(in: .newlines)
        } catch is CommandTimedOut {
            entries[index].output =
                "⏱ No result after 60s — long-running commands aren't supported here. The connection was reset; reconnect to continue."
            await disconnect()
        } catch {
            entries[index].output = "error: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        await session?.close()
        session = nil
        state = .disconnected
    }
}
