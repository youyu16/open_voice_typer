import XCTest
@testable import OpenVoiceTyper

final class WAVEncodingTests: XCTestCase {
    func testWavHeaderIsWellFormed() {
        let pcm = Data(repeating: 0xAB, count: 32_000) // 1s of 16kHz mono Int16
        let wav = AudioRecorder.wavFile(fromPCM: pcm)

        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        // Sample rate at offset 24, little-endian.
        let sampleRate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: sampleRate), 16_000)
    }

    func testAudioSecondsFromWav() {
        let wav = AudioRecorder.wavFile(fromPCM: Data(count: 64_000)) // 2s
        XCTAssertEqual(DictationPipeline.audioSeconds(ofWAV: wav), 2.0, accuracy: 0.001)
    }
}

final class MultipartDialectTests: XCTestCase {
    private func formBody(baseURL: String, hotwords: [String]) async throws -> String {
        let received = ReceivedBox()
        StubURLProtocol.stub(host: URL(string: baseURL)!.host()!) { _, body in
            received.set(body)
            return .init(body: Data(#"{"text":"ok"}"#.utf8))
        }
        defer { StubURLProtocol.reset() }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let asr = OpenAICompatibleASR(
            baseURL: baseURL,
            model: "test-model",
            apiKey: { "sk-test" },
            session: URLSession(configuration: config)
        )
        _ = try await asr.transcribe(ASRRequest(wavData: Data(count: 100), hotwords: hotwords))
        return String(decoding: received.get(), as: UTF8.self)
    }

    func testOpenAIDialectSendsPromptAndResponseFormat() async throws {
        let body = try await formBody(baseURL: "https://api.openai.com/v1", hotwords: ["XcodeGen", "Wispr"])
        XCTAssertTrue(body.contains("name=\"response_format\""))
        XCTAssertTrue(body.contains("name=\"prompt\""))
        XCTAssertTrue(body.contains("XcodeGen, Wispr"))
        XCTAssertFalse(body.contains("name=\"stream\""))
    }

    func testGLMDialectSendsStreamFalseAndNoPrompt() async throws {
        let body = try await formBody(baseURL: "https://open.bigmodel.cn/api/paas/v4", hotwords: ["XcodeGen"])
        XCTAssertTrue(body.contains("name=\"stream\""))
        XCTAssertFalse(body.contains("name=\"prompt\""), "GLM has no Whisper prompt field")
        XCTAssertFalse(body.contains("name=\"response_format\""))
        XCTAssertTrue(body.contains("glm") == false && body.contains("test-model"))
    }
}

final class PromptBuilderTests: XCTestCase {
    func testPromptContainsBaseRulesStyleAndDictionary() {
        let prompt = PromptBuilder.systemPrompt(for: PolishRequest(
            transcript: "whatever",
            style: .formal,
            dictionary: ["OpenVoiceTyper"],
            targetLanguage: "English"
        ))
        XCTAssertTrue(prompt.contains("NEVER answer"))
        XCTAssertTrue(prompt.contains("professional register"))
        XCTAssertTrue(prompt.contains("- OpenVoiceTyper"))
    }

    func testTranslateStyleSubstitutesTargetLanguage() {
        let prompt = PromptBuilder.systemPrompt(for: PolishRequest(
            transcript: "whatever",
            style: .translate,
            targetLanguage: "Japanese"
        ))
        XCTAssertTrue(prompt.contains("Japanese"))
        XCTAssertFalse(prompt.contains("{{TARGET_LANGUAGE}}"))
    }
}

final class PresetTests: XCTestCase {
    func testPresetsCoverRequestedProviders() {
        XCTAssertTrue(ProviderPreset.asr.contains { $0.model == "glm-asr-2512" })
        XCTAssertTrue(ProviderPreset.asr.contains { $0.baseURL.contains("groq.com") })
    }

    /// A polish preset only rewrites the generic backend's base URL, and the
    /// generic backend has one shared key slot. Offering a preset for a
    /// provider that is *also* first-class would therefore route the user
    /// around its own key and model — the same trap DeepSeek was pulled out of.
    func testPolishPresetsNeverShadowAFirstClassBackend() {
        let firstClassHosts = PolishBackendSpec.all
            .compactMap { $0.makeVerifyTarget(ProviderSettings()).origin?.host() }
            .filter { $0 != "api.openai.com" } // the generic backend's own default
        for preset in ProviderPreset.polish {
            let host = URL(string: preset.baseURL)?.host() ?? ""
            XCTAssertFalse(
                firstClassHosts.contains(host),
                "\(preset.name) is a first-class backend; a preset would bypass its key slot"
            )
        }
    }

    /// A preset is a one-tap promise that the endpoint works, so each needs a
    /// usable URL, a model, and — for anything hosted — somewhere to get a
    /// key. A preset you can't authenticate is a dead end.
    func testEveryPresetIsUsable() {
        for preset in ProviderPreset.asr + ProviderPreset.polish {
            let url = URL(string: preset.baseURL)
            XCTAssertNotNil(url?.host(), "\(preset.name) has no host")
            XCTAssertFalse(preset.model.isEmpty, "\(preset.name) names no model")
            if url?.scheme == "https" {
                XCTAssertNotNil(
                    ProviderConsole.keyURL(forBaseURL: preset.baseURL),
                    "\(preset.name) doesn't say where to get a key"
                )
            }
        }
        // A provider may appear in both menus (OpenAI does both jobs), but
        // twice in the same menu is a duplicate row the user has to read past.
        for menu in [ProviderPreset.asr, ProviderPreset.polish] {
            XCTAssertEqual(Set(menu.map(\.name)).count, menu.count, "duplicate preset name in one menu")
        }
    }

    /// The self-hosted preset is plain HTTP on the LAN, which iOS blocks
    /// outright unless the app opts into local networking — without these keys
    /// it is a button that can only ever fail.
    func testSelfHostedPresetsCanActuallyConnect() {
        let info = Bundle.main.infoDictionary
        let ats = info?["NSAppTransportSecurity"] as? [String: Any]
        XCTAssertEqual(ats?["NSAllowsLocalNetworking"] as? Bool, true,
                       "cleartext to a local server is blocked without NSAllowsLocalNetworking")
        XCTAssertNotNil(info?["NSLocalNetworkUsageDescription"],
                        "iOS gates local-network access behind a usage description")

        let cleartext = (ProviderPreset.asr + ProviderPreset.polish)
            .filter { URL(string: $0.baseURL)?.scheme != "https" }
        XCTAssertFalse(cleartext.isEmpty, "expected at least one self-hosted preset")
        for preset in cleartext {
            XCTAssertEqual(preset.name, "Local server",
                           "\(preset.name) reaches the internet in cleartext")
        }
    }

    func testDeepSeekIsFirstClassPolishBackend() {
        XCTAssertTrue(ProviderSettings.PolishBackend.allCases.contains(.deepseek))
        XCTAssertEqual(ProviderSettings().deepseekModel, "deepseek-v4-flash")
        XCTAssertTrue(PolishBackendSpec.for(.deepseek).presetModels.contains("deepseek-v4-pro"))
    }
}

final class PolishBackendSpecTests: XCTestCase {
    func testRegistryHasExactlyOneSpecPerBackend() {
        XCTAssertEqual(
            PolishBackendSpec.all.count,
            ProviderSettings.PolishBackend.allCases.count,
            "registry must stay exhaustive — one spec per backend"
        )
        for backend in ProviderSettings.PolishBackend.allCases {
            XCTAssertEqual(PolishBackendSpec.for(backend).backend, backend)
        }
    }

    func testKeychainKeysAreDistinctPerBackend() {
        let keys = PolishBackendSpec.all.map(\.keychainKey)
        XCTAssertEqual(Set(keys).count, keys.count, "each backend needs its own key slot")
    }

    func testModelKeyPathsResolveToTheRightField() {
        var settings = ProviderSettings()
        settings.deepseekModel = "deepseek-v4-pro"
        settings.anthropicModel = "claude-x"
        settings.groqModel = "groq-x"
        settings.mistralModel = "mistral-x"
        XCTAssertEqual(PolishBackendSpec.for(.deepseek).model(in: settings), "deepseek-v4-pro")
        XCTAssertEqual(PolishBackendSpec.for(.anthropic).model(in: settings), "claude-x")
        XCTAssertEqual(PolishBackendSpec.for(.groq).model(in: settings), "groq-x")
        XCTAssertEqual(PolishBackendSpec.for(.mistral).model(in: settings), "mistral-x")
    }

    /// Two backends sharing a model field would silently overwrite each
    /// other's choice when the user switched providers.
    func testEveryBackendHasItsOwnModelField() {
        var settings = ProviderSettings()
        for (index, spec) in PolishBackendSpec.all.enumerated() {
            settings[keyPath: spec.modelKeyPath] = "model-\(index)"
        }
        let models = PolishBackendSpec.all.map { $0.model(in: settings) }
        XCTAssertEqual(Set(models).count, models.count, "a model field is shared between backends")
    }

    func testEveryBackendPointsSomewhereToGetAKey() {
        for spec in PolishBackendSpec.all {
            let url = spec.makeGetKeyURL(ProviderSettings()).flatMap(URL.init(string:))
            XCTAssertNotNil(url, "\(spec.backend) offers no way to get a key")
        }
    }

    /// The whole point of a separate slot is that configuring one engine never
    /// disturbs another — including across the ASR/polish boundary, where a
    /// reused slot would mean an ElevenLabs key overwriting an OpenAI one.
    func testEveryEngineAndBackendKeySlotIsDistinct() {
        let polishSlots = PolishBackendSpec.all.map(\.keychainKey)
        let asrSlots: [KeychainStore.Key] = [.asrAPIKey, .asrElevenLabsKey]
        let all = polishSlots + asrSlots
        XCTAssertEqual(Set(all).count, all.count, "two engines share a Keychain slot")
        XCTAssertEqual(Set(KeychainStore.Key.allCases.map(\.rawValue)).count,
                       KeychainStore.Key.allCases.count,
                       "two Keychain keys share a raw value")
    }

    func testElevenLabsIsAFirstClassASREngine() {
        XCTAssertTrue(ProviderSettings.ASRBackend.allCases.contains(.elevenLabs))
        XCTAssertEqual(ProviderSettings().elevenLabsModel, "scribe_v1")
        XCTAssertFalse(ProviderSettings.ASRBackend.elevenLabs.hasConfigurableBaseURL,
                       "Scribe is a fixed endpoint, not a base URL to point anywhere")
        XCTAssertNotNil(
            ProviderConsole.keyURL(forBaseURL: ElevenLabsASR.endpoint.absoluteString),
            "no way to get an ElevenLabs key"
        )
    }

    func testOnlyOpenAICompatibleHasAConfigurableBaseURL() {
        // Every branded backend is a fixed endpoint; only the generic
        // "OpenAI-compatible" one lets the user point it anywhere.
        for spec in PolishBackendSpec.all {
            XCTAssertEqual(
                spec.hasConfigurableBaseURL,
                spec.backend == .openAICompatible,
                "\(spec.backend) has the wrong base-URL configurability"
            )
        }
    }
}

final class SettingsMigrationTests: XCTestCase {
    /// Settings saved before `deepseekModel` (or any later field) existed must
    /// decode intact, not reset to defaults.
    func testOlderSettingsPayloadDecodesWithNewFieldsDefaulted() throws {
        let old = #"{"asrBackend":"apple","polishBackend":"anthropic","anthropicModel":"claude-3-5-haiku","sessionAutoEndMinutes":60}"#
        let settings = try JSONDecoder().decode(ProviderSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.polishBackend, .anthropic)
        XCTAssertEqual(settings.anthropicModel, "claude-3-5-haiku")
        XCTAssertEqual(settings.sessionAutoEndMinutes, 60)
        XCTAssertEqual(settings.deepseekModel, "deepseek-v4-flash", "missing field should take the default")
        XCTAssertEqual(settings.elevenLabsModel, "scribe_v1", "missing field should take the default")
        XCTAssertEqual(settings.asrBackend, .apple, "an engine added later must not disturb the saved one")
    }

    func testInvalidTargetLanguageClampsToDefault() throws {
        let bad = try JSONDecoder().decode(ProviderSettings.self, from: Data(#"{"targetLanguage":"Klingon"}"#.utf8))
        XCTAssertEqual(bad.targetLanguage, "English", "an unknown language must clamp to the default")

        let good = try JSONDecoder().decode(ProviderSettings.self, from: Data(#"{"targetLanguage":"Japanese"}"#.utf8))
        XCTAssertEqual(good.targetLanguage, "Japanese", "a known language must be preserved")
    }
}

final class AsyncRetryTests: XCTestCase {
    private actor Counter {
        private(set) var count = 0
        func bump() -> Int { count += 1; return count }
    }

    func testRetriesTimeoutThenSucceeds() async throws {
        let counter = Counter()
        let result = try await AsyncRetry.retryingOnTimeout(maxAttempts: 3, timeout: .milliseconds(80)) {
            let n = await counter.bump()
            if n < 3 { try await Task.sleep(for: .milliseconds(400)) } // first two time out
            return "done"
        }
        XCTAssertEqual(result, "done")
        let attempts = await counter.count
        XCTAssertEqual(attempts, 3, "should have retried twice before succeeding on the third try")
    }

    func testNonTimeoutErrorFailsImmediately() async {
        let counter = Counter()
        do {
            _ = try await AsyncRetry.retryingOnTimeout(maxAttempts: 3, timeout: .seconds(5)) { () async throws -> String in
                _ = await counter.bump()
                throw PolishError.missingAPIKey
            }
            XCTFail("a non-timeout error should propagate, not retry")
        } catch {
            XCTAssertTrue(error is PolishError)
        }
        let attempts = await counter.count
        XCTAssertEqual(attempts, 1, "a bad-key error must not be retried")
    }

    func testExhaustsRetriesThenThrowsTimeout() async {
        let counter = Counter()
        do {
            _ = try await AsyncRetry.retryingOnTimeout(maxAttempts: 3, timeout: .milliseconds(60)) { () async throws -> String in
                _ = await counter.bump()
                try await Task.sleep(for: .milliseconds(400)) // always times out
                return "never"
            }
            XCTFail("should throw after exhausting retries")
        } catch {
            XCTAssertTrue(error is TimeoutError, "final failure should be a timeout")
        }
        let attempts = await counter.count
        XCTAssertEqual(attempts, 3, "should try the full budget of attempts")
    }
}

/// Boxes captured request bodies across the Sendable stub boundary.
final class ReceivedBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
