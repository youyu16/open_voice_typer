import AVFoundation
import Foundation
import Speech

/// On-device transcription via Apple's Speech framework — free, offline, and
/// the default before any API key is configured.
///
/// Recognition order: the iOS 26 `SpeechAnalyzer` stack (downloads its own
/// model assets, works in the simulator), then `SFSpeechRecognizer` on-device,
/// then `SFSpeechRecognizer` server-based — SFSpeech is broken on iOS 17+
/// simulators (kAFAssistantErrorDomain 1101) and needs downloaded dictation
/// assets on devices, so it is the fallback, not the default.
struct AppleSpeechASR: ASRProvider {
    /// Empty means the current locale.
    var language: String = ""

    func transcribe(_ request: ASRRequest) async throws -> String {
        let status = await SpeechWarmup.shared.authorizationStatus()
        guard status == .authorized else { throw ASRError.speechPermissionDenied }

        let localeID = request.language.isEmpty ? language : request.language
        let locale = SpeechWarmup.locale(for: localeID)

        // Both stacks want a file on disk.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")
        try request.wavData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var analyzerFailure: String?
        do {
            return try await transcribeWithAnalyzer(fileURL: fileURL, locale: locale)
        } catch let error as ASRError {
            throw error
        } catch {
            // Model assets unavailable or locale unsupported — fall through
            // to the legacy recognizer, but keep the reason for diagnostics.
            analyzerFailure = String(describing: error)
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ASRError.recognizerUnavailable
        }

        // supportsOnDeviceRecognition can report true while the on-device
        // model assets are absent (simulators always; devices until iOS has
        // downloaded dictation assets), which fails with "Failed to
        // initialize recognizer". Prefer on-device, fall back to Apple's
        // server-based recognition.
        if recognizer.supportsOnDeviceRecognition {
            do {
                return try await recognize(with: recognizer, fileURL: fileURL, hotwords: request.hotwords, onDeviceOnly: true)
            } catch let error as ASRError {
                throw error
            } catch {
                // Fall through to the network path below.
            }
        }
        do {
            return try await recognize(with: recognizer, fileURL: fileURL, hotwords: request.hotwords, onDeviceOnly: false)
        } catch let error as ASRError {
            throw error
        } catch {
            #if targetEnvironment(simulator)
            // Neither speech stack can run in the iOS Simulator (no speech
            // model catalog); don't send users chasing settings that won't help.
            throw ASRError.appleUnavailableInSimulator
            #else
            var reason = error.localizedDescription
            if let analyzerFailure {
                reason += " (SpeechAnalyzer: \(analyzerFailure))"
            }
            throw ASRError.appleRecognitionFailed(reason)
            #endif
        }
    }

    /// iOS 26 SpeechAnalyzer path. Throws a plain error (not ASRError) when
    /// the environment can't run it, so the caller falls back to SFSpeech.
    private func transcribeWithAnalyzer(fileURL: URL, locale: Locale) async throws -> String {
        // Locale support and model-asset installation are settled by
        // `SpeechWarmup` — normally while the user was still speaking, so this
        // returns immediately instead of paying for both after the fact.
        guard await SpeechWarmup.shared.isAnalyzerReady(for: locale) else {
            throw AnalyzerUnavailable()
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Attach the collector before feeding audio so no result is missed.
        let collector = Task {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = (try await collector.value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ASRError.emptyTranscript }
        return text
    }

    private struct AnalyzerUnavailable: Error {}

    private func recognize(
        with recognizer: SFSpeechRecognizer,
        fileURL: URL,
        hotwords: [String],
        onDeviceOnly: Bool
    ) async throws -> String {
        let recognitionRequest = SFSpeechURLRecognitionRequest(url: fileURL)
        recognitionRequest.shouldReportPartialResults = false
        recognitionRequest.contextualStrings = hotwords
        recognitionRequest.requiresOnDeviceRecognition = onDeviceOnly

        let text: String = try await withCheckedThrowingContinuation { continuation in
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                    task = nil
                } else if let error {
                    continuation.resume(throwing: error)
                    task = nil
                }
            }
            _ = task
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ASRError.emptyTranscript }
        return trimmed
    }
}
