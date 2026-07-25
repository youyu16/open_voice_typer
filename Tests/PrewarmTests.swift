import XCTest
@testable import OpenVoiceTyper

/// The setup that was moved off the post-speech critical path and onto the
/// window where the user is still talking. If a backend stops yielding a
/// warmable host, its dictations quietly go back to paying for DNS + TCP + TLS
/// after the user stops speaking — which is invisible in a simulator and very
/// visible on cellular, so the registry sweep matters as much as the parsing.
final class PrewarmTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Origin derivation

    func testOriginKeepsSchemeHostAndPortAndDropsThePath() {
        XCTAssertEqual(
            ConnectionWarmer.origin(ofBaseURL: "https://api.openai.com/v1")?.absoluteString,
            "https://api.openai.com/"
        )
        XCTAssertEqual(
            ConnectionWarmer.origin(ofBaseURL: " https://api.groq.com/openai/v1/ ")?.absoluteString,
            "https://api.groq.com/"
        )
        // A self-hosted endpoint: the port is part of the connection, so it
        // must survive — warming :443 would warm the wrong socket.
        XCTAssertEqual(
            ConnectionWarmer.origin(ofBaseURL: "http://192.168.1.4:8080/v1")?.absoluteString,
            "http://192.168.1.4:8080/"
        )
    }

    func testOriginIsNilWhenThereIsNothingToConnectTo() {
        XCTAssertNil(ConnectionWarmer.origin(ofBaseURL: ""))
        XCTAssertNil(ConnectionWarmer.origin(ofBaseURL: "/v1"), "a relative path names no host")
        XCTAssertNil(ConnectionWarmer.origin(ofBaseURL: "api.openai.com/v1"), "no scheme, no connection")
    }

    // MARK: Registry coverage

    func testEveryPolishBackendExposesAWarmableHost() {
        let settings = ProviderSettings()
        for spec in PolishBackendSpec.all {
            let origin = spec.makeVerifyTarget(settings).origin
            XCTAssertNotNil(origin, "\(spec.backend) has no host to warm")
            XCTAssertEqual(origin?.path, "/", "\(spec.backend) should warm an origin, not a path")
        }
    }

    func testWarmedHostIsTheHostPolishActuallyPosts() {
        // The value of warming is entirely in hitting the *same* host the real
        // request will, so it can reuse the pooled connection.
        var settings = ProviderSettings()
        settings.polishBaseURL = "https://llm.example.test/v1"
        let expected: [ProviderSettings.PolishBackend: String] = [
            .openAICompatible: "llm.example.test",
            .deepseek: "api.deepseek.com",
            .anthropic: "api.anthropic.com",
            .gemini: "generativelanguage.googleapis.com",
            .groq: "api.groq.com",
            .openRouter: "openrouter.ai",
            .xai: "api.x.ai",
            .mistral: "api.mistral.ai",
        ]
        for spec in PolishBackendSpec.all {
            XCTAssertEqual(
                spec.makeVerifyTarget(settings).origin?.host(),
                expected[spec.backend],
                "\(spec.backend) warms the wrong host"
            )
        }
    }

    // MARK: Warming behaviour

    func testWarmingIssuesAnUnauthenticatedHeadAndSkipsRepeats() async {
        let counter = HitCounter()
        let firstHit = expectation(description: "the warm-up reached the host")
        StubURLProtocol.stub(host: "warm.stub.test") { request, _ in
            XCTAssertEqual(request.httpMethod, "HEAD", "a warm-up must not transfer a body")
            XCTAssertNil(
                request.value(forHTTPHeaderField: "Authorization"),
                "a warm-up must never carry credentials"
            )
            if counter.increment() == 1 { firstHit.fulfill() }
            return .init(body: Data())
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let warmer = ConnectionWarmer(session: URLSession(configuration: config))
        let origin = ConnectionWarmer.origin(ofBaseURL: "https://warm.stub.test/v1")

        // The nil stands in for an unusable base URL: a warm-up is an
        // optimization and must never become a source of errors.
        await warmer.warm([origin, nil])
        await fulfillment(of: [firstHit], timeout: 3)

        await warmer.warm([origin])
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counter.value, 1, "a host warmed moments ago must not be warmed again")
    }
}

/// Counts stub hits from whatever queue URLSession delivers them on.
private final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}
