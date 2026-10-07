import Foundation

/// URLSession implementation of the BrickAPI port. Every request goes through
/// the EndpointResolver, so callers never know (or care) whether the winning
/// route is Tailscale or the home LAN.
final class HTTPBrickClient: BrickAPI {
    private let resolver: EndpointResolver
    private let tokens: TokenStore
    private let session: URLSession

    init(resolver: EndpointResolver, tokens: TokenStore) {
        self.resolver = resolver
        self.tokens = tokens
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Session

    func pair(code: String) async throws -> PairingGrant {
        try await request("POST", "/api/v1/pair",
                          body: ["code": code, "client_name": "iPhone"],
                          authenticated: false)
    }

    func identity() async throws -> BrickIdentity {
        try await request("GET", "/api/v1/identity")
    }

    func overview() async throws -> BrickOverview {
        try await request("GET", "/api/v1/overview")
    }

    // MARK: - Ad Blocking

    func adBlockStats() async throws -> AdBlockStats {
        try await request("GET", "/api/v1/adguard/stats")
    }

    func setAdBlocking(enabled: Bool) async throws -> BrickActionResult {
        try await request("POST", "/api/v1/adguard/protection", body: ["enabled": enabled])
    }

    func queryLog(limit: Int, search: String?) async throws -> [QueryLogEntry] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let search, !search.isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        let page: QueryLogPage = try await request("GET", "/api/v1/adguard/querylog", query: query)
        return page.entries
    }

    func blocklists() async throws -> [Blocklist] {
        let page: BlocklistPage = try await request("GET", "/api/v1/adguard/blocklists")
        return page.blocklists
    }

    func addBlocklist(name: String, url: String) async throws -> BrickActionResult {
        try await request("POST", "/api/v1/adguard/blocklists", body: ["name": name, "url": url])
    }

    func removeBlocklist(url: String) async throws -> BrickActionResult {
        try await request("POST", "/api/v1/adguard/blocklists/remove", body: ["url": url])
    }

    func setDomainRule(domain: String, action: DomainRuleAction) async throws -> BrickActionResult {
        try await request("POST", "/api/v1/adguard/rules",
                          body: ["domain": domain, "action": action.rawValue])
    }

    // MARK: - Private DNS

    func dnsStats() async throws -> DNSStats {
        try await request("GET", "/api/v1/unbound/stats")
    }

    func flushDNSCache() async throws -> BrickActionResult {
        try await request("POST", "/api/v1/unbound/flush-cache")
    }

    func restartPrivateDNS() async throws -> BrickActionResult {
        try await request("POST", "/api/v1/unbound/restart")
    }

    // MARK: - Remote Access

    func remoteAccessStatus() async throws -> RemoteAccessStatus {
        try await request("GET", "/api/v1/tailscale/status")
    }

    func setRemoteAccess(enabled: Bool) async throws -> BrickActionResult {
        try await request("POST", enabled ? "/api/v1/tailscale/up" : "/api/v1/tailscale/down")
    }

    // MARK: - Cloud Filtering

    func setCloudFiltering(enabled: Bool) async throws -> BrickActionResult {
        try await request(
            "POST", enabled ? "/api/v1/nextdns/activate" : "/api/v1/nextdns/deactivate"
        )
    }

    // MARK: - Network Monitor

    func networkDevices() async throws -> [NetworkDevice] {
        let page: NetworkDevicePage = try await request("GET", "/api/v1/ntopng/hosts")
        return page.hosts
    }

    // MARK: - Whole-Home Protection (DHCP takeover)

    func dhcpStatus() async throws -> DHCPStatus {
        try await request("GET", "/api/v1/dhcp/status")
    }

    func dhcpCheck() async throws -> DHCPCheck {
        try await request("POST", "/api/v1/dhcp/check")
    }

    func enableDHCP(force: Bool) async throws -> DHCPEnableResult {
        try await request("POST", "/api/v1/dhcp/enable", body: ["force": force])
    }

    func disableDHCP() async throws -> BrickActionResult {
        try await request("POST", "/api/v1/dhcp/disable")
    }

    func routerInfo() async throws -> RouterInfo {
        try await request("GET", "/api/v1/system/router")
    }

    // MARK: - Remote Console

    func installSSHKey(publicKey: String) async throws -> BrickActionResult {
        try await request("POST", "/api/v1/system/ssh-key", body: ["public_key": publicKey])
    }

    // MARK: - Device

    func deviceHealth() async throws -> DeviceHealth {
        try await request("GET", "/api/v1/system/info")
    }

    func rebootDevice() async throws -> BrickActionResult {
        try await request("POST", "/api/v1/system/reboot")
    }

    func startUpdate() async throws -> BrickActionResult {
        try await request("POST", "/api/v1/system/update")
    }

    func updateStatus() async throws -> UpdateStatus {
        try await request("GET", "/api/v1/system/update/status")
    }

    // MARK: - Core machinery

    private func request<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws -> Response {
        do {
            return try await send(method, path, query: query, body: body, authenticated: authenticated)
        } catch BrickError.unreachable where method == "GET" {
            // One bounded retry for idempotent reads: the cached route may
            // have just died (left home WiFi, Tailscale woke up) — re-probe.
            resolver.invalidate()
            return try await send(method, path, query: query, body: body, authenticated: authenticated)
        }
    }

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: [String: Any]?,
        authenticated: Bool
    ) async throws -> Response {
        let endpoint = try await resolver.resolve()
        guard let base = endpoint.url,
              var components = URLComponents(url: base.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false)
        else { throw BrickError.unreachable }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw BrickError.unreachable }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        if authenticated {
            guard let token = tokens.token else { throw BrickError.notPaired }
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            resolver.invalidate()
            throw BrickError.unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw BrickError.unreachable }
        switch http.statusCode {
        case 200 ..< 300:
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw BrickError.deviceError("The device sent an unexpected response.")
            }
        case 401:
            throw BrickError.unauthorized
        case 403 where path.hasSuffix("/pair"):
            throw BrickError.pairingRejected(Self.detail(from: data)
                ?? "Wrong or expired code. Get a fresh one from the device.")
        default:
            throw BrickError.deviceError(Self.detail(from: data)
                ?? "The device returned an error (\(http.statusCode)).")
        }
    }

    private static func detail(from data: Data) -> String? {
        struct Detail: Decodable { let detail: String }
        return (try? JSONDecoder().decode(Detail.self, from: data))?.detail
    }
}
