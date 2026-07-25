import XCTest
@testable import OpenVoiceTyper

/// Provider clients exercised end-to-end (request building → response
/// parsing) against stubbed HTTP responses in real provider shapes.
final class ProviderTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private let request = PolishRequest(transcript: "um hello there", style: .light)

    func testOpenAICompatiblePolishParsesChoices() async throws {
        StubURLProtocol.stub(host: "api.deepseek.com") { urlRequest, body in
            XCTAssertEqual(urlRequest.url?.path(), "/chat/completions")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ds")
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["model"] as? String, "deepseek-v4-flash")
            return .init(body: Data(#"{"choices":[{"message":{"content":"Hello there."}}]}"#.utf8))
        }
        let provider = OpenAICompatibleLLM(
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKey: { "sk-ds" },
            session: session
        )
        let output = try await provider.polish(request)
        XCTAssertEqual(output, "Hello there.")
    }

    func testAnthropicPolishParsesContentBlocks() async throws {
        StubURLProtocol.stub(host: "api.anthropic.com") { urlRequest, body in
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertNotNil(json["system"])
            return .init(body: Data(#"{"content":[{"type":"text","text":"Hello "},{"type":"text","text":"there."}]}"#.utf8))
        }
        let provider = AnthropicLLM(apiKey: { "sk-ant" }, session: session)
        let output = try await provider.polish(request)
        XCTAssertEqual(output, "Hello there.")
    }

    func testGeminiPolishParsesCandidates() async throws {
        StubURLProtocol.stub(host: "generativelanguage.googleapis.com") { urlRequest, body in
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-goog-api-key"), "sk-gem")
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertNotNil(json["system_instruction"])
            return .init(body: Data(#"{"candidates":[{"content":{"parts":[{"text":"Hello there."}]}}]}"#.utf8))
        }
        let provider = GeminiLLM(apiKey: { "sk-gem" }, session: session)
        let output = try await provider.polish(request)
        XCTAssertEqual(output, "Hello there.")
    }

    /// Polish reshapes a transcript, it never reasons about one — and Gemini's
    /// Flash models think by default, which puts seconds between the user
    /// finishing a sentence and seeing it typed.
    func testGeminiFlashPolishSpendsNothingOnThinking() async throws {
        StubURLProtocol.stub(host: "generativelanguage.googleapis.com") { _, body in
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            let thinking = (json["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
            XCTAssertEqual(thinking?["thinkingBudget"] as? Int, 0)
            return .init(body: Data(#"{"candidates":[{"content":{"parts":[{"text":"Hello there."}]}}]}"#.utf8))
        }
        let provider = GeminiLLM(model: "gemini-2.5-flash", apiKey: { "sk-gem" }, session: session)
        let output = try await provider.polish(request)
        XCTAssertEqual(output, "Hello there.")
    }

    /// Pro models have a thinking floor and non-thinking models reject the
    /// field outright, so the budget is only sent where it is known to be
    /// accepted — a faster polish is not worth a 400.
    func testGeminiLeavesOtherModelsOnTheirDefaults() async throws {
        StubURLProtocol.stub(host: "generativelanguage.googleapis.com") { _, body in
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertNil(json["generationConfig"])
            return .init(body: Data(#"{"candidates":[{"content":{"parts":[{"text":"Hello there."}]}}]}"#.utf8))
        }
        let provider = GeminiLLM(model: "gemini-2.5-pro", apiKey: { "sk-gem" }, session: session)
        let output = try await provider.polish(request)
        XCTAssertEqual(output, "Hello there.")
    }

    // MARK: ElevenLabs Scribe

    /// Scribe is not an OpenAI-compatible endpoint — different path, different
    /// auth header, different model field — which is exactly why it needs its
    /// own client rather than a base-URL preset.
    func testElevenLabsSendsScribeDialect() async throws {
        StubURLProtocol.stub(host: "api.elevenlabs.io") { urlRequest, body in
            XCTAssertEqual(urlRequest.url?.path(), "/v1/speech-to-text")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "xi-api-key"), "sk-11l")
            XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"),
                         "Scribe authenticates by xi-api-key, not Bearer")
            let form = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(form.contains("name=\"file\""), "audio file part missing")
            XCTAssertTrue(form.contains("name=\"model_id\""), "Scribe names the model model_id")
            XCTAssertTrue(form.contains("scribe_v1"))
            XCTAssertTrue(form.contains("name=\"language_code\""), "language hint missing")
            XCTAssertTrue(form.contains("de"))
            // Dictation, not transcription of a recording: nobody wants
            // "(clears throat)" typed into their message.
            XCTAssertTrue(form.contains("name=\"tag_audio_events\""))
            XCTAssertTrue(form.contains("false"))
            return .init(body: Data(#"{"language_code":"de","text":"Guten Tag."}"#.utf8))
        }
        let provider = ElevenLabsASR(model: "scribe_v1", apiKey: { "sk-11l" }, session: session)
        let text = try await provider.transcribe(
            ASRRequest(wavData: Data("fake-wav".utf8), language: "de", hotwords: ["OpenVoiceTyper"])
        )
        XCTAssertEqual(text, "Guten Tag.")
    }

    func testElevenLabsTreatsAnEmptyTranscriptAsAFailure() async {
        StubURLProtocol.stub(host: "api.elevenlabs.io") { _, _ in
            .init(body: Data(#"{"language_code":"en","text":"   "}"#.utf8))
        }
        let provider = ElevenLabsASR(apiKey: { "sk-11l" }, session: session)
        do {
            _ = try await provider.transcribe(ASRRequest(wavData: Data("fake-wav".utf8)))
            XCTFail("expected an error")
        } catch ASRError.emptyTranscript {
            // expected: silence must not insert an empty string
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testElevenLabsSurfacesHTTPFailures() async {
        StubURLProtocol.stub(host: "api.elevenlabs.io") { _, _ in
            .init(status: 401, body: Data(#"{"detail":{"message":"invalid api key"}}"#.utf8))
        }
        let provider = ElevenLabsASR(apiKey: { "sk-bad" }, session: session)
        do {
            _ = try await provider.transcribe(ASRRequest(wavData: Data("fake-wav".utf8)))
            XCTFail("expected an error")
        } catch let ASRError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("invalid api key"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testElevenLabsFailsBeforeAnyRequestWithoutAKey() async {
        let provider = ElevenLabsASR(apiKey: { nil }, session: session)
        do {
            _ = try await provider.transcribe(ASRRequest(wavData: Data("fake-wav".utf8)))
            XCTFail("expected an error")
        } catch ASRError.missingAPIKey {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testHTTPErrorSurfacesStatusAndBody() async {
        StubURLProtocol.stub(host: "api.openai.com") { _, _ in
            .init(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
        let provider = OpenAICompatibleLLM(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            apiKey: { "sk-bad" },
            session: session
        )
        do {
            _ = try await provider.polish(request)
            XCTFail("expected error")
        } catch let PolishError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("bad key"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let provider = OpenAICompatibleLLM(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            apiKey: { nil },
            session: session
        )
        do {
            _ = try await provider.polish(request)
            XCTFail("expected error")
        } catch is PolishError {
            // expected: .missingAPIKey
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
