import Foundation
import Speech

/// Per-process cache for the Speech-framework setup that `AppleSpeechASR`
/// would otherwise redo on every single dictation: authorization, the
/// supported-locale query, and the on-device asset installation request.
///
/// Each of those is a round trip to the speech daemon and the asset check is
/// the slow one — and all of them sat *between* "the user stopped talking" and
/// the first byte of transcription, on the default path that every user gets
/// before configuring an API key. `prepare(language:)` runs them when
/// recording starts instead, so they overlap the user speaking and the
/// transcription that follows finds the answers already cached.
///
/// Only successes are remembered. A failed asset install is usually transient
/// (no network on first run, storage pressure), and caching that would strand
/// the app on the slower `SFSpeechRecognizer` path until it was force-quit.
actor SpeechWarmup {
    static let shared = SpeechWarmup()

    /// In-flight or finished readiness check per BCP-47 locale.
    private var analyzerChecks: [String: Task<Bool, Never>] = [:]
    private var authorizationCheck: Task<SFSpeechRecognizerAuthorizationStatus, Never>?

    /// Called when recording begins. Errors are the caller's problem later —
    /// this only takes the cost off the critical path.
    func prepare(language: String) async {
        let locale = Self.locale(for: language)
        guard await authorizationStatus() == .authorized else { return }
        _ = await isAnalyzerReady(for: locale)
    }

    /// Cached `SFSpeechRecognizer.requestAuthorization`. A denial is *not*
    /// cached: the user can grant permission in Settings and come straight
    /// back without relaunching.
    func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        if let authorizationCheck { return await authorizationCheck.value }
        let check = Task {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        authorizationCheck = check
        let status = await check.value
        if status != .authorized { authorizationCheck = nil }
        return status
    }

    /// Whether the iOS 26 `SpeechAnalyzer` stack can transcribe this locale —
    /// including having its model assets installed. Concurrent callers share
    /// one check rather than each kicking off their own asset download.
    func isAnalyzerReady(for locale: Locale) async -> Bool {
        let key = locale.identifier(.bcp47)
        let check = analyzerChecks[key] ?? {
            let check = Task { await Self.installAssets(for: locale) }
            analyzerChecks[key] = check
            return check
        }()

        let ready = await check.value
        if !ready { analyzerChecks[key] = nil }
        return ready
    }

    private static func installAssets(for locale: Locale) async -> Bool {
        guard await SpeechTranscriber.supportedLocales.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else { return false }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        do {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
            return true
        } catch {
            return false
        }
    }

    /// Empty means "whatever the device is set to".
    nonisolated static func locale(for language: String) -> Locale {
        language.isEmpty ? Locale.current : Locale(identifier: language)
    }
}
