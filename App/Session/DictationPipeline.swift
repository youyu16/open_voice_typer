import Foundation
import os

/// Runs one dictation through ASR and (unless the style is Raw) polish,
/// using whatever providers the current settings select. Each network hop
/// goes through `AsyncRetry` so a hung request is retried, not fatal.
struct DictationPipeline: Sendable {
    struct Outcome: Sendable {
        var rawText: String
        var polishedText: String
        /// Model that produced the final text ("on-device", "gpt-4o-mini", …).
        var engineName: String
        var audioSeconds: Double
    }

    var settings: ProviderSettings

    /// 16 kHz mono 16-bit WAV: 32,000 audio bytes per second after the header.
    static func audioSeconds(ofWAV wavData: Data) -> Double {
        Double(max(0, wavData.count - 44)) / 32_000
    }

    var asrEngineName: String {
        switch settings.asrBackend {
        case .apple: "on-device"
        case .openAICompatible: settings.asrModel
        }
    }

    var polishEngineName: String {
        PolishBackendSpec.for(settings.polishBackend).model(in: settings)
    }

    /// Does everything a dictation needs that doesn't depend on the audio, so
    /// it can happen while the user is still speaking rather than after they
    /// stop: TLS handshakes to the provider hosts, and the on-device speech
    /// model's authorization/asset checks. Best-effort — anything that fails
    /// here simply costs what it always did when the real request runs.
    func prewarm(style: Style) async {
        var origins: [URL?] = []
        if case .openAICompatible = settings.asrBackend {
            origins.append(ConnectionWarmer.origin(ofBaseURL: settings.asrBaseURL))
        }
        if style.id != Style.raw.id {
            origins.append(PolishBackendSpec.for(settings.polishBackend).makeVerifyTarget(settings).origin)
        }
        await ConnectionWarmer.shared.warm(origins)

        // Deliberately last: it can take a while on first run, and it must not
        // hold up handshakes that only need to be *started*.
        if case .apple = settings.asrBackend {
            await SpeechWarmup.shared.prepare(language: settings.asrLanguage)
        }
    }

    func run(wavData: Data, style: Style) async throws -> Outcome {
        let dictionary = SharedCatalog.loadDictionary().map(\.term)
        let seconds = Self.audioSeconds(ofWAV: wavData)

        #if DEBUG
        // UI-test hook: the simulator has no working speech stack and test
        // runs have no API keys, so E2E tests fake only the provider calls —
        // recording, the keyboard↔app bridge, and insertion all stay real.
        if let fake = ProcessInfo.processInfo.environment["OVT_FAKE_PIPELINE"] {
            try? await Task.sleep(for: .milliseconds(300))
            return Outcome(rawText: fake, polishedText: fake, engineName: "uitest-fake", audioSeconds: seconds)
        }
        #endif

        // ASR and polish are separate network hops, so each gets its own
        // timeout-and-retry budget: a slow/hung request is abandoned and
        // retried rather than stalling the whole dictation.
        let asr = makeASRProvider()
        let asrStart = ContinuousClock.now
        let raw = try await AsyncRetry.retryingOnTimeout {
            try await asr.transcribe(ASRRequest(
                wavData: wavData,
                language: settings.asrLanguage,
                hotwords: dictionary
            ))
        }
        let asrDuration = ContinuousClock.now - asrStart

        guard style.id != Style.raw.id else {
            Self.logStages(audio: seconds, asr: asrDuration, polish: nil)
            return Outcome(rawText: raw, polishedText: raw, engineName: asrEngineName, audioSeconds: seconds)
        }

        let polishStart = ContinuousClock.now
        let polished = try await polish(rawText: raw, style: style, dictionary: dictionary)
        Self.logStages(audio: seconds, asr: asrDuration, polish: ContinuousClock.now - polishStart)

        return Outcome(rawText: raw, polishedText: polished, engineName: polishEngineName, audioSeconds: seconds)
    }

    /// Reruns just the polish stage — used by History's Re-polish and the
    /// template editor's preview.
    func polishOnly(rawText: String, style: Style) async throws -> String {
        guard style.id != Style.raw.id else { return rawText }
        return try await polish(
            rawText: rawText,
            style: style,
            dictionary: SharedCatalog.loadDictionary().map(\.term)
        )
    }

    /// The dictionary is passed in rather than reloaded: `run` already read it
    /// for ASR hotwords, and it is a file read plus a JSON decode.
    private func polish(rawText: String, style: Style, dictionary: [String]) async throws -> String {
        let polisher = makePolishProvider()
        let request = PolishRequest(
            transcript: rawText,
            style: style,
            dictionary: dictionary,
            targetLanguage: settings.targetLanguage
        )
        return try await AsyncRetry.retryingOnTimeout {
            try await polisher.polish(request)
        }
    }

    // MARK: Instrumentation

    private static let log = Logger(subsystem: "com.shuaiwang.openvoicetyper", category: "pipeline")

    /// Stage timings, so the wait after a dictation can be attributed instead
    /// of guessed at. Read with Console/Instruments attached to the app.
    private static func logStages(audio: Double, asr: Duration, polish: Duration?) {
        log.info("""
        dictation audio=\(audio, format: .fixed(precision: 1))s \
        asr=\(asr.milliseconds)ms \
        polish=\(polish.map { "\($0.milliseconds)ms" } ?? "skipped", privacy: .public)
        """)
    }

    // MARK: Provider construction

    private func makeASRProvider() -> ASRProvider {
        switch settings.asrBackend {
        case .apple:
            AppleSpeechASR(language: settings.asrLanguage)
        case .openAICompatible:
            OpenAICompatibleASR(
                baseURL: settings.asrBaseURL,
                model: settings.asrModel,
                apiKey: { KeychainStore.get(.asrAPIKey) }
            )
        }
    }

    private func makePolishProvider() -> PolishProvider {
        PolishBackendSpec.for(settings.polishBackend).makeProvider(settings)
    }
}

private extension Duration {
    var milliseconds: Int {
        Int(components.seconds) * 1_000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
