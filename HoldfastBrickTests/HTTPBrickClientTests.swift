import XCTest
@testable import HoldfastBrick

/// The bearer token must never ride a plain-http fallback connection: a
/// TLS-minted token requires re-pairing before it may cross http, and only a
/// session that paired over plaintext (a dev brick) may send it at all.
final class HTTPBrickClientTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "HTTPBrickClientTests")!
        defaults.removePersistentDomain(forName: "HTTPBrickClientTests")
    }

    /// Records every request the client makes and answers with a valid
    /// overview payload.
    private final class TransportRecorder: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        private let lock = NSLock()

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            requests.append(request)
            lock.unlock()
            let body: Data
            if request.url?.path.hasSuffix("/pair") == true {
                body = Data("""
                {"token": "fresh-token", "device_name": "Brick", "cert_fingerprint": null}
                """.utf8)
            } else {
                body = Data("""
                {"device_name": "Brick", "protected": true, "services": []}
                """.utf8)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (body, response)
        }
    }

    /// A brick that answers plain http only, with a null cert fingerprint
    /// (a TLS-less dev brick).
    private func makeClient(plaintextPaired: Bool) async -> (HTTPBrickClient, TransportRecorder) {
        let resolver = EndpointResolver(defaults: defaults, probe: { url in
            url.scheme == "https" ? .noAnswer : .answered(certFingerprint: nil)
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        let recorder = TransportRecorder()
        let tokens = MemoryTokenStore()
        tokens.save("secret-token")
        let client = HTTPBrickClient(resolver: resolver, tokens: tokens) { request in
            try await recorder.send(request)
        }
        if plaintextPaired {
            // Mirror the real pairing order: pair() resolves first (which is
            // what flags the plaintext transport), then the /pair response
            // licenses the session.
            _ = try? await resolver.resolve()
            resolver.notePairing(certFingerprint: nil)
        }
        return (client, recorder)
    }

    func testTLSMintedTokenIsNeverSentOverPlainHTTP() async {
        let (client, recorder) = await makeClient(plaintextPaired: false)

        do {
            _ = try await client.overview()
            XCTFail("authenticated requests over a plain-http fallback must be refused")
        } catch let error as BrickError {
            XCTAssertEqual(error, .insecureTransport)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(recorder.requests.allSatisfy { request in
            request.value(forHTTPHeaderField: "Authorization") == nil
        }, "no request may carry the token over plain http")
    }

    func testPlaintextPairedSessionMaySendTokenOverPlainHTTP() async throws {
        let (client, recorder) = await makeClient(plaintextPaired: true)

        let overview = try await client.overview()

        XCTAssertEqual(overview.deviceName, "Brick")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.scheme, "http")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testTokenRidesHTTPSRequests() async throws {
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in
            .answered(certFingerprint: MockBrickAPI.certFingerprint)
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        let recorder = TransportRecorder()
        let tokens = MemoryTokenStore()
        tokens.save("secret-token")
        let client = HTTPBrickClient(resolver: resolver, tokens: tokens) { request in
            try await recorder.send(request)
        }

        _ = try await client.overview()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testPairingRequestCarriesNoToken() async throws {
        let resolver = EndpointResolver(defaults: defaults, probe: { _ in
            .answered(certFingerprint: nil)
        })
        resolver.adopt(lanHost: "192.168.1.42", port: 8787)
        let recorder = TransportRecorder()
        let tokens = MemoryTokenStore()
        tokens.save("secret-token")
        let client = HTTPBrickClient(resolver: resolver, tokens: tokens) { request in
            try await recorder.send(request)
        }

        let grant = try await client.pair(code: "123456")

        XCTAssertEqual(grant.token, "fresh-token")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "pairing must never send a token, even over TLS")
    }
}
