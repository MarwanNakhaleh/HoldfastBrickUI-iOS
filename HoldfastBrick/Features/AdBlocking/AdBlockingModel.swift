import Foundation
import Observation

/// State for the Ad Blocking feature: stats, recent activity, blocklists.
@Observable
@MainActor
final class AdBlockingModel {
    private let api: BrickAPI

    private(set) var stats: AdBlockStats?
    private(set) var entries: [QueryLogEntry] = []
    private(set) var blocklists: [Blocklist] = []
    private(set) var wholeHomeEnabled: Bool?
    private(set) var isLoading = false
    var errorMessage: String?
    var searchText = ""

    init(api: BrickAPI) {
        self.api = api
    }

    func loadStats() async {
        do {
            stats = try await api.adBlockStats()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Status line for the Whole-Home Protection entry row. Best-effort:
    /// if the brick can't answer, the row just says "Set up".
    func loadWholeHomeStatus() async {
        wholeHomeEnabled = (try? await api.dhcpStatus())?.enabled
    }

    func loadQueryLog() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await api.queryLog(
                limit: 50,
                search: searchText.isEmpty ? nil : searchText
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadBlocklists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            blocklists = try await api.blocklists()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addBlocklist(name: String, url: String) async -> Bool {
        do {
            let result = try await api.addBlocklist(name: name, url: url)
            if !result.ok { errorMessage = result.message }
            await loadBlocklists()
            return result.ok
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeBlocklist(_ blocklist: Blocklist) async {
        do {
            let result = try await api.removeBlocklist(url: blocklist.url)
            if !result.ok { errorMessage = result.message }
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadBlocklists()
    }

    /// Allow or block a single domain straight from the activity list.
    func setRule(domain: String, action: DomainRuleAction) async {
        do {
            let result = try await api.setDomainRule(domain: domain, action: action)
            if !result.ok { errorMessage = result.message }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
