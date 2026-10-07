import Foundation
import Observation

/// State machine for the guided DHCP-takeover flow: intro → check the network
/// → (blocker while the router still serves DHCP) → ready → enabled.
@Observable
@MainActor
final class WholeHomeModel {
    enum State: Equatable {
        case loading
        case intro
        case blocked(check: DHCPCheck, router: RouterInfo?)
        case ready
        case enabled(DHCPStatus)
    }

    private let api: BrickAPI

    private(set) var state: State = .loading
    private(set) var isWorking = false
    private(set) var needsReboot = false
    var errorMessage: String?

    init(api: BrickAPI) {
        self.api = api
    }

    /// Pure derivation, kept static so it's unit-testable: only a clean
    /// "no other DHCP server" answer unlocks the enable step. "yes", probe
    /// errors, and unrecognized answers all keep the blocker up.
    static func state(afterCheck check: DHCPCheck, router: RouterInfo?) -> State {
        check.otherDHCP == .no ? .ready : .blocked(check: check, router: router)
    }

    /// Refresh from the brick. An enabled brick always wins; otherwise the
    /// user keeps their place mid-flow (blocker / ready survive a refresh).
    func load() async {
        do {
            let status = try await api.dhcpStatus()
            if status.enabled {
                state = .enabled(status)
            } else {
                switch state {
                case .loading, .enabled: state = .intro
                default: break
                }
            }
            errorMessage = nil
        } catch {
            if state == .loading { state = .intro }
            errorMessage = error.localizedDescription
        }
    }

    /// Probe the network and identify the router, in parallel. Router info is
    /// best-effort — without it the blocker shows generic instructions.
    func check() async {
        isWorking = true
        defer { isWorking = false }
        do {
            async let checkCall = api.dhcpCheck()
            async let routerCall = api.routerInfo()
            let check = try await checkCall
            let router = try? await routerCall
            state = Self.state(afterCheck: check, router: router)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func enable(force: Bool = false) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await api.enableDHCP(force: force)
            if result.ok {
                needsReboot = result.needsReboot
                errorMessage = nil
                await load()
            } else {
                errorMessage = result.message
            }
        } catch let BrickError.deviceError(message) {
            // 409 (router DHCP is back) or 422 (static IP needs manual setup):
            // surface the server's words, then re-probe so the screen lands on
            // the right step — the blocker for 409, ready-with-message for 422.
            errorMessage = message
            await recheckPreservingError()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disable() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await api.disableDHCP()
            guard result.ok else {
                // Stay on the enabled screen with the server's words —
                // reloading here would wipe the message and look like a no-op.
                errorMessage = result.message
                return
            }
            errorMessage = nil
            needsReboot = false
            state = .loading
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Finish a takeover that needs a restart to apply cleanly.
    func reboot() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await api.rebootDevice()
            needsReboot = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recheckPreservingError() async {
        let message = errorMessage
        await check()
        if errorMessage == nil { errorMessage = message }
    }
}
