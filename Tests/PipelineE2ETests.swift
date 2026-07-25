import XCTest
@testable import OpenVoiceTyper

/// The full dictation pipeline — provider factory, multipart audio upload,
/// hotword propagation, prompt building, polish, outcome metadata — run
/// end-to-end over stubbed provider HTTP. Uses global URLProtocol
/// registration because the pipeline's providers use `URLSession.shared`.
final class PipelineE2ETests: XCTestCase {
    private var savedSettings: ProviderSettings!
    private var savedDictionary: [DictionaryEntry]!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
        savedSettings = SettingsStore.load()
        savedDictionary = SharedCatalog.loadDictionary()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        SettingsStore.save(savedSettings)
        SharedCatalog.saveDictionary(savedDictionary)
        KeychainStore.Key.allCases.forEach(KeychainStore.delete)
        super.tearDown()
    }

    func testFullPipelineCloudASRPlusPolish() async throws {
        // Arrange: cloud ASR + OpenAI-compatible polish, one dictionary term.
        var settings = ProviderSettings()
        settings.asrBackend = .openAICompatible
        settings.asrBaseURL = "https://asr.stub.test/v1"
        settings.asrModel = "whisper-large-v3-turbo"
        settings.polishBackend = .openAICompatible
        settings.polishBaseURL = "https://llm.stub.test/v1"
        settings.polishModel = "test-polish-model"
        KeychainStore.set("sk-asr-test", for: .asrAPIKey)
        KeychainStore.set("sk-llm-test", for: .polishOpenAIKey)
        SharedCatalog.saveDictionary([DictionaryEntry(term: "OpenVoiceTyper")])

        StubURLProtocol.stub(host: "asr.stub.test") { request, body in
            XCTAssertEqual(request.url?.path(), "/v1/audio/transcriptions")
            let form = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(form.contains("name=\"file\""), "audio file part missing")
            XCTAssertTrue(form.contains("OpenVoiceTyper"), "dictionary hotword missing from ASR prompt")
            return .init(body: Data(#"{"text":"um hello open voice typer test"}"#.utf8))
        }
        StubURLProtocol.stub(host: "llm.stub.test") { _, body in
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            let messages = json["messages"] as! [[String: Any]]
            let system = messages[0]["content"] as! String
            XCTAssertTrue(system.contains("NEVER answer"), "base rules missing")
            XCTAssertTrue(system.contains("OpenVoiceTyper"), "dictionary missing from polish prompt")
            XCTAssertEqual(messages[1]["content"] as! String, "um hello open voice typer test")
            return .init(body: Data(#"{"choices":[{"message":{"content":"Hello, OpenVoiceTyper test."}}]}"#.utf8))
        }

        // Act: run the real pipeline over the synthesized speech fixture.
        let wav = try fixtureWAV()
        let outcome = try await DictationPipeline(settings: settings).run(wavData: wav, style: .light)

        // Assert: both stages ran and metadata is right.
        XCTAssertEqual(outcome.rawText, "um hello open voice typer test")
        XCTAssertEqual(outcome.polishedText, "Hello, OpenVoiceTyper test.")
        XCTAssertEqual(outcome.engineName, "test-polish-model")
        // afconvert pads the fixture header, so the 44-byte-header estimate
        // reads slightly high; recorder-produced WAVs are exact.
        XCTAssertEqual(outcome.audioSeconds, 2.2, accuracy: 0.15)
    }

    func testRawStyleSkipsPolishEntirely() async throws {
        var settings = ProviderSettings()
        settings.asrBackend = .openAICompatible
        settings.asrBaseURL = "https://asr.stub.test/v1"
        settings.asrModel = "whisper-1"
        KeychainStore.set("sk-asr-test", for: .asrAPIKey)

        StubURLProtocol.stub(host: "asr.stub.test") { _, _ in
            .init(body: Data(#"{"text":"verbatim words"}"#.utf8))
        }
        // No polish stub: any polish call would fail the test with unsupportedURL.

        let outcome = try await DictationPipeline(settings: settings)
            .run(wavData: try fixtureWAV(), style: .raw)
        XCTAssertEqual(outcome.polishedText, "verbatim words")
        XCTAssertEqual(outcome.engineName, "whisper-1")
    }

    func testDeepSeekBackendUsesFixedEndpointAndOwnKey() async throws {
        var settings = ProviderSettings()
        settings.polishBackend = .deepseek
        settings.deepseekModel = "deepseek-v4-pro"
        KeychainStore.set("sk-ds-test", for: .polishDeepSeekKey)
        // A key in the shared OpenAI-compatible slot must NOT be used.
        KeychainStore.set("sk-wrong-slot", for: .polishOpenAIKey)

        StubURLProtocol.stub(host: "api.deepseek.com") { request, body in
            XCTAssertEqual(request.url?.path(), "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ds-test")
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["model"] as? String, "deepseek-v4-pro")
            return .init(body: Data(#"{"choices":[{"message":{"content":"Polished by DeepSeek."}}]}"#.utf8))
        }

        let pipeline = DictationPipeline(settings: settings)
        let polished = try await pipeline.polishOnly(rawText: "um hello", style: .light)
        XCTAssertEqual(polished, "Polished by DeepSeek.")
        XCTAssertEqual(pipeline.polishEngineName, "deepseek-v4-pro")
    }

    /// Every fixed-endpoint backend must reach its own host carrying its own
    /// key. The registry makes adding a provider a six-line declaration, which
    /// is only safe if a wrong key slot or endpoint can't slip through — so
    /// this loops the registry rather than naming providers, and a new one is
    /// covered the moment it is declared.
    func testEveryFixedEndpointBackendUsesItsOwnHostAndKey() async throws {
        for spec in PolishBackendSpec.all where !spec.hasConfigurableBaseURL {
            var settings = ProviderSettings()
            settings.polishBackend = spec.backend

            // The backend under test gets the real key; every other slot gets
            // a decoy, so reaching for the wrong one is caught rather than
            // silently working because both slots held the same value.
            let expectedKey = "sk-\(spec.backend.rawValue)-real"
            for key in KeychainStore.Key.allCases {
                KeychainStore.set(key == spec.keychainKey ? expectedKey : "sk-decoy", for: key)
            }

            let host = try XCTUnwrap(
                spec.makeVerifyTarget(settings).origin?.host(),
                "\(spec.backend) has no endpoint host"
            )
            StubURLProtocol.reset()
            StubURLProtocol.stub(host: host) { request, _ in
                let credential = request.value(forHTTPHeaderField: "Authorization")?
                    .replacingOccurrences(of: "Bearer ", with: "")
                    ?? request.value(forHTTPHeaderField: "x-api-key")
                    ?? request.value(forHTTPHeaderField: "x-goog-api-key")
                XCTAssertEqual(credential, expectedKey, "\(spec.backend) sent the wrong key")
                return .init(body: Data("""
                {"choices":[{"message":{"content":"ok"}}],\
                "content":[{"type":"text","text":"ok"}],\
                "candidates":[{"content":{"parts":[{"text":"ok"}]}}]}
                """.utf8))
            }

            let polished = try await DictationPipeline(settings: settings)
                .polishOnly(rawText: "um hello", style: .light)
            XCTAssertEqual(polished, "ok", "\(spec.backend) did not come back with a transcript")
        }
    }

    /// The ElevenLabs engine has to be reachable through the real pipeline —
    /// its own key slot, its own endpoint, and its model reported to history —
    /// not just as a provider in isolation.
    func testElevenLabsEngineRunsThroughThePipeline() async throws {
        var settings = ProviderSettings()
        settings.asrBackend = .elevenLabs
        settings.elevenLabsModel = "scribe_v1_experimental"
        settings.polishBackend = .openAICompatible
        settings.polishBaseURL = "https://llm.stub.test/v1"
        KeychainStore.set("sk-11l-real", for: .asrElevenLabsKey)
        // The OpenAI-compatible ASR slot must not be reached for.
        KeychainStore.set("sk-wrong-slot", for: .asrAPIKey)
        KeychainStore.set("sk-llm-test", for: .polishOpenAIKey)

        StubURLProtocol.stub(host: "api.elevenlabs.io") { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "sk-11l-real")
            return .init(body: Data(#"{"text":"um hello there"}"#.utf8))
        }
        StubURLProtocol.stub(host: "llm.stub.test") { _, _ in
            .init(body: Data(#"{"choices":[{"message":{"content":"Hello there."}}]}"#.utf8))
        }

        let outcome = try await DictationPipeline(settings: settings)
            .run(wavData: try fixtureWAV(), style: .light)
        XCTAssertEqual(outcome.rawText, "um hello there")
        XCTAssertEqual(outcome.polishedText, "Hello there.")

        // Raw style skips polish, so the engine name is the ASR model — that
        // is what history shows for an ElevenLabs dictation.
        let raw = try await DictationPipeline(settings: settings)
            .run(wavData: try fixtureWAV(), style: .raw)
        XCTAssertEqual(raw.engineName, "scribe_v1_experimental")
    }

    /// History's timing readout is only as honest as what the pipeline
    /// reports: every stage that ran must be measured, the total must cover
    /// the whole run rather than just the stages, and a skipped stage must
    /// come back as zero rather than as a small bogus number.
    func testThePipelineReportsWhereTheTimeWent() async throws {
        var settings = ProviderSettings()
        settings.asrBackend = .openAICompatible
        settings.asrBaseURL = "https://asr.stub.test/v1"
        settings.polishBackend = .openAICompatible
        settings.polishBaseURL = "https://llm.stub.test/v1"
        KeychainStore.set("sk-asr-test", for: .asrAPIKey)
        KeychainStore.set("sk-llm-test", for: .polishOpenAIKey)

        // Each stage sleeps so the measurements are distinguishable from zero
        // and from each other.
        StubURLProtocol.stub(host: "asr.stub.test") { _, _ in
            Thread.sleep(forTimeInterval: 0.20)
            return .init(body: Data(#"{"text":"um hello there"}"#.utf8))
        }
        StubURLProtocol.stub(host: "llm.stub.test") { _, _ in
            Thread.sleep(forTimeInterval: 0.10)
            return .init(body: Data(#"{"choices":[{"message":{"content":"Hello there."}}]}"#.utf8))
        }

        let outcome = try await DictationPipeline(settings: settings)
            .run(wavData: try fixtureWAV(), style: .light)

        XCTAssertGreaterThanOrEqual(outcome.asrMilliseconds, 200)
        XCTAssertGreaterThanOrEqual(outcome.polishMilliseconds, 100)
        XCTAssertGreaterThanOrEqual(
            outcome.totalMilliseconds,
            outcome.asrMilliseconds + outcome.polishMilliseconds,
            "the total must cover the whole run, not just the two stages"
        )

        // Raw skips polish — that stage really did take no time.
        let raw = try await DictationPipeline(settings: settings)
            .run(wavData: try fixtureWAV(), style: .raw)
        XCTAssertEqual(raw.polishMilliseconds, 0, "a skipped stage is zero, not a small number")
        XCTAssertGreaterThanOrEqual(raw.asrMilliseconds, 200)
        XCTAssertGreaterThanOrEqual(raw.totalMilliseconds, raw.asrMilliseconds)
    }

    private func fixtureWAV() throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "hello", withExtension: "wav") else {
            throw XCTSkip("hello.wav fixture not bundled")
        }
        return try Data(contentsOf: url)
    }
}
