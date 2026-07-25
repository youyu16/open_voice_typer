import Foundation

/// Everything the app needs to know about one polish backend, in a single
/// place. Adding a provider means adding one `PolishBackendSpec` to `all`
/// (plus its enum case + Keychain slot) — the pipeline and the settings UI
/// read from here instead of each carrying their own `switch`.
/// `@unchecked Sendable`: the only non-`Sendable`-inferred members are the
/// key paths, which are immutable value-semantics descriptors and safe to
/// share across threads.
struct PolishBackendSpec: @unchecked Sendable {
    let backend: ProviderSettings.PolishBackend
    /// Keychain slot holding this backend's API key.
    let keychainKey: KeychainStore.Key
    /// Settings field holding this backend's model name.
    let modelKeyPath: WritableKeyPath<ProviderSettings, String>
    /// Settings field for the base URL, or nil for a fixed endpoint.
    let baseURLKeyPath: WritableKeyPath<ProviderSettings, String>?
    /// Fixed model choices offered as a quick-pick; empty = free text only.
    let presetModels: [String]
    /// Where to send the user to create a key (nil = unknown / derived).
    let makeGetKeyURL: @Sendable (ProviderSettings) -> String?
    /// Builds the live provider for a dictation.
    let makeProvider: @Sendable (ProviderSettings) -> PolishProvider
    /// How to verify this backend's key before dictating.
    let makeVerifyTarget: @Sendable (ProviderSettings) -> KeyVerifier.Target

    var displayName: String { backend.displayName }
    var hasConfigurableBaseURL: Bool { baseURLKeyPath != nil }
    func model(in settings: ProviderSettings) -> String { settings[keyPath: modelKeyPath] }
}

extension PolishBackendSpec {
    /// One entry per `ProviderSettings.PolishBackend`. `specForBackendTests`
    /// asserts this stays exhaustive.
    static let all: [PolishBackendSpec] = [
        PolishBackendSpec(
            backend: .openAICompatible,
            keychainKey: .polishOpenAIKey,
            modelKeyPath: \.polishModel,
            baseURLKeyPath: \.polishBaseURL,
            presetModels: [],
            makeGetKeyURL: { ProviderConsole.keyURL(forBaseURL: $0.polishBaseURL) },
            makeProvider: { settings in
                OpenAICompatibleLLM(
                    baseURL: settings.polishBaseURL,
                    model: settings.polishModel,
                    apiKey: { KeychainStore.get(.polishOpenAIKey) }
                )
            },
            makeVerifyTarget: { .openAICompatible(baseURL: $0.polishBaseURL) }
        ),
        .hosted(
            .deepseek,
            key: .polishDeepSeekKey,
            model: \.deepseekModel,
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-v4-flash", "deepseek-v4-pro"],
            console: "https://platform.deepseek.com/api_keys"
        ),
        .hosted(
            .groq,
            key: .polishGroqKey,
            model: \.groqModel,
            baseURL: "https://api.groq.com/openai/v1",
            models: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"],
            console: "https://console.groq.com/keys"
        ),
        .hosted(
            .openRouter,
            key: .polishOpenRouterKey,
            model: \.openRouterModel,
            baseURL: "https://openrouter.ai/api/v1",
            models: ["openai/gpt-4o-mini", "google/gemini-2.5-flash", "meta-llama/llama-3.3-70b-instruct"],
            console: "https://openrouter.ai/keys"
        ),
        .hosted(
            .xai,
            key: .polishXAIKey,
            model: \.xaiModel,
            baseURL: "https://api.x.ai/v1",
            models: ["grok-4-fast", "grok-3-mini"],
            console: "https://console.x.ai"
        ),
        .hosted(
            .mistral,
            key: .polishMistralKey,
            model: \.mistralModel,
            baseURL: "https://api.mistral.ai/v1",
            models: ["mistral-small-latest", "mistral-medium-latest", "ministral-8b-latest"],
            console: "https://console.mistral.ai/api-keys"
        ),
        PolishBackendSpec(
            backend: .anthropic,
            keychainKey: .polishAnthropicKey,
            modelKeyPath: \.anthropicModel,
            baseURLKeyPath: nil,
            presetModels: [],
            makeGetKeyURL: { _ in "https://console.anthropic.com/settings/keys" },
            makeProvider: { settings in
                AnthropicLLM(
                    model: settings.anthropicModel,
                    apiKey: { KeychainStore.get(.polishAnthropicKey) }
                )
            },
            makeVerifyTarget: { _ in .anthropic }
        ),
        PolishBackendSpec(
            backend: .gemini,
            keychainKey: .polishGeminiKey,
            modelKeyPath: \.geminiModel,
            baseURLKeyPath: nil,
            presetModels: [],
            makeGetKeyURL: { _ in "https://aistudio.google.com/apikey" },
            makeProvider: { settings in
                GeminiLLM(
                    model: settings.geminiModel,
                    apiKey: { KeychainStore.get(.polishGeminiKey) }
                )
            },
            makeVerifyTarget: { _ in .gemini }
        ),
    ]

    /// A branded OpenAI-compatible backend. Most providers are exactly this:
    /// the same client and the same key verification, differing only in
    /// endpoint, key slot, model field and where you go to get a key — so they
    /// are *declared* rather than written out, and adding the next one is six
    /// lines of fact with no new code paths to review.
    ///
    /// The endpoint and its model shortlist live here rather than in
    /// `ProviderSettings`: they are facts about the provider, not choices the
    /// user has made.
    static func hosted(
        _ backend: ProviderSettings.PolishBackend,
        key: KeychainStore.Key,
        model: WritableKeyPath<ProviderSettings, String>,
        baseURL: String,
        models: [String] = [],
        console: String
    ) -> PolishBackendSpec {
        // Same reasoning as the type's `@unchecked Sendable`: a key path is an
        // immutable value-semantics descriptor, safe to read from any thread.
        nonisolated(unsafe) let modelPath = model
        return PolishBackendSpec(
            backend: backend,
            keychainKey: key,
            modelKeyPath: model,
            // Fixed endpoint: nothing for the user to configure, and nothing
            // for a base-URL preset to overwrite.
            baseURLKeyPath: nil,
            presetModels: models,
            makeGetKeyURL: { _ in console },
            makeProvider: { settings in
                OpenAICompatibleLLM(
                    baseURL: baseURL,
                    model: settings[keyPath: modelPath],
                    apiKey: { KeychainStore.get(key) }
                )
            },
            makeVerifyTarget: { _ in .openAICompatible(baseURL: baseURL) }
        )
    }

    static func `for`(_ backend: ProviderSettings.PolishBackend) -> PolishBackendSpec {
        // Force-unwrap is intentional: a missing spec is a wiring bug that
        // `PolishBackendSpecTests` catches immediately.
        all.first { $0.backend == backend }!
    }
}

/// Maps a known API host to its key-management console URL. Shared by the
/// polish registry and the ASR key row.
enum ProviderConsole {
    static func keyURL(forBaseURL baseURL: String) -> String? {
        let host = URL(string: baseURL)?.host() ?? baseURL
        if host.contains("openai.com") { return "https://platform.openai.com/api-keys" }
        if host.contains("groq.com") { return "https://console.groq.com/keys" }
        if host.contains("deepseek.com") { return "https://platform.deepseek.com/api_keys" }
        if host.contains("openrouter.ai") { return "https://openrouter.ai/keys" }
        if host.contains("mistral.ai") { return "https://console.mistral.ai/api-keys" }
        if host.contains("x.ai") { return "https://console.x.ai" }
        if host.contains("cerebras.ai") { return "https://cloud.cerebras.ai" }
        if host.contains("together.xyz") { return "https://api.together.xyz/settings/api-keys" }
        if host.contains("fireworks.ai") { return "https://fireworks.ai/account/api-keys" }
        if host.contains("z.ai") { return "https://z.ai/manage-apikey/apikey-list" }
        if host.contains("bigmodel.cn") { return "https://open.bigmodel.cn/usercenter/apikeys" }
        return nil
    }
}
