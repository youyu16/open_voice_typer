import Foundation

/// Provider and pipeline configuration. Lives in App Group defaults so the
/// keyboard can read the selected style; API keys are NOT here — they stay in
/// the app-only Keychain.
struct ProviderSettings: Codable, Equatable, Sendable {
    enum ASRBackend: String, Codable, CaseIterable, Sendable {
        case apple
        case openAICompatible
        case elevenLabs

        var displayName: String {
            switch self {
            case .apple: "On-device"
            case .openAICompatible: "Cloud (OpenAI-compatible)"
            case .elevenLabs: "ElevenLabs Scribe"
            }
        }

        /// Whether the engine is configured by base URL + model (the generic
        /// OpenAI dialect) rather than being a fixed endpoint of its own.
        var hasConfigurableBaseURL: Bool { self == .openAICompatible }
    }

    /// Order here is the order of the Settings picker. Raw values are what get
    /// persisted, so they must never change; the ordering is free to.
    enum PolishBackend: String, Codable, CaseIterable, Sendable {
        case openAICompatible
        case anthropic
        case gemini
        case groq
        case openRouter
        case deepseek
        case xai
        case mistral

        var displayName: String {
            switch self {
            case .openAICompatible: "OpenAI-compatible"
            case .anthropic: "Anthropic"
            case .gemini: "Google Gemini"
            case .groq: "Groq"
            case .openRouter: "OpenRouter"
            case .deepseek: "DeepSeek"
            case .xai: "xAI (Grok)"
            case .mistral: "Mistral"
            }
        }
    }

    var asrBackend: ASRBackend = .apple
    var asrBaseURL: String = "https://api.openai.com/v1"
    var asrModel: String = "gpt-4o-transcribe"
    /// Kept apart from `asrModel` for the same reason each polish backend owns
    /// its model field: switching engines must not lose the other's setup.
    var elevenLabsModel: String = "scribe_v1"
    /// ISO-639 hint for ASR; empty = auto-detect / current locale.
    var asrLanguage: String = ""

    static let elevenLabsModels = ["scribe_v1", "scribe_v1_experimental"]

    var polishBackend: PolishBackend = .openAICompatible
    var polishBaseURL: String = "https://api.openai.com/v1"
    var polishModel: String = "gpt-5.6-luna"
    /// One model field per fixed-endpoint backend, so switching providers
    /// keeps each one's model (and, with its own Keychain slot, its key) —
    /// you can flip between them without re-entering anything.
    ///
    /// Defaults favour each provider's fast, cheap tier: polish is a mechanical
    /// rewrite of a sentence or two, so the flagship models cost seconds of
    /// added latency for output the user can't tell apart. Anything here can be
    /// overtyped, and every backend offers its larger models as a quick-pick.
    var deepseekModel: String = "deepseek-v4-flash"
    var anthropicModel: String = "claude-haiku-4-5"
    var geminiModel: String = "gemini-3.5-flash-lite"
    var groqModel: String = "openai/gpt-oss-20b"
    var openRouterModel: String = "openai/gpt-5.6-luna"
    var xaiModel: String = "grok-4.5"
    var mistralModel: String = "mistral-small-4-0-26-03"

    var selectedStyleID: String = Style.light.id
    /// The template to return to when the keyboard's Dictate/Translate toggle
    /// leaves translate mode — the last non-translate selection.
    var lastDictateStyleID: String = Style.light.id
    var targetLanguage: String = "English"

    /// Whether History shows the per-stage latency of each dictation. The
    /// timings are recorded either way — this only reveals them, so switching
    /// it on explains the dictations already behind you, not just the next one.
    var showsTimings: Bool = false

    /// Keyboard mic idle-timeout, in minutes; 0 means never. Measured from
    /// the last dictation, not from when the session started.
    var sessionAutoEndMinutes: Int = 60

    static let autoEndChoices: [(label: String, minutes: Int)] = [
        ("5 minutes", 5),
        ("15 minutes", 15),
        ("1 hour", 60),
        ("Never", 0),
    ]

    /// Translate targets the user can choose from — a fixed list so an
    /// unrecognized / misspelled language can never reach the polish prompt.
    static let targetLanguages = [
        "English", "Spanish", "French", "German", "Italian", "Portuguese",
        "Dutch", "Russian", "Polish", "Turkish", "Arabic", "Hindi",
        "Chinese (Simplified)", "Chinese (Traditional)", "Japanese", "Korean",
        "Vietnamese", "Thai", "Indonesian", "Ukrainian",
    ]

    init() {}

    /// Every field is optional on decode so settings saved by an older build
    /// (before a field existed) load intact instead of resetting to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProviderSettings()
        asrBackend = try c.decodeIfPresent(ASRBackend.self, forKey: .asrBackend) ?? defaults.asrBackend
        asrBaseURL = try c.decodeIfPresent(String.self, forKey: .asrBaseURL) ?? defaults.asrBaseURL
        asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel) ?? defaults.asrModel
        asrLanguage = try c.decodeIfPresent(String.self, forKey: .asrLanguage) ?? defaults.asrLanguage
        elevenLabsModel = try c.decodeIfPresent(String.self, forKey: .elevenLabsModel) ?? defaults.elevenLabsModel
        polishBackend = try c.decodeIfPresent(PolishBackend.self, forKey: .polishBackend) ?? defaults.polishBackend
        polishBaseURL = try c.decodeIfPresent(String.self, forKey: .polishBaseURL) ?? defaults.polishBaseURL
        polishModel = try c.decodeIfPresent(String.self, forKey: .polishModel) ?? defaults.polishModel
        deepseekModel = try c.decodeIfPresent(String.self, forKey: .deepseekModel) ?? defaults.deepseekModel
        anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel) ?? defaults.anthropicModel
        geminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel) ?? defaults.geminiModel
        groqModel = try c.decodeIfPresent(String.self, forKey: .groqModel) ?? defaults.groqModel
        openRouterModel = try c.decodeIfPresent(String.self, forKey: .openRouterModel) ?? defaults.openRouterModel
        xaiModel = try c.decodeIfPresent(String.self, forKey: .xaiModel) ?? defaults.xaiModel
        mistralModel = try c.decodeIfPresent(String.self, forKey: .mistralModel) ?? defaults.mistralModel
        selectedStyleID = try c.decodeIfPresent(String.self, forKey: .selectedStyleID) ?? defaults.selectedStyleID
        lastDictateStyleID = try c.decodeIfPresent(String.self, forKey: .lastDictateStyleID) ?? defaults.lastDictateStyleID
        let decodedLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? defaults.targetLanguage
        // Clamp a language saved by an older build (freeform text) to the
        // known list so an invalid target never reaches the polish prompt.
        targetLanguage = Self.targetLanguages.contains(decodedLanguage) ? decodedLanguage : defaults.targetLanguage
        sessionAutoEndMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionAutoEndMinutes) ?? defaults.sessionAutoEndMinutes
        showsTimings = try c.decodeIfPresent(Bool.self, forKey: .showsTimings) ?? defaults.showsTimings
    }
}

/// One-tap base URL + model for a known OpenAI-compatible provider.
struct ProviderPreset: Identifiable {
    let name: String
    let baseURL: String
    let model: String
    var id: String { name }

    /// Every entry must speak the Whisper-style OpenAI dialect — multipart
    /// `POST {baseURL}/audio/transcriptions` answering `{"text": …}` — because
    /// that is the only shape `OpenAICompatibleASR` sends. Providers with
    /// their own protocol (Deepgram, ElevenLabs Scribe, AssemblyAI) need a
    /// client of their own, not a preset.
    static let asr: [ProviderPreset] = [
        .init(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-transcribe"),
        .init(name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
        .init(name: "Together", baseURL: "https://api.together.xyz/v1", model: "openai/whisper-large-v3"),
        .init(name: "DeepInfra", baseURL: "https://api.deepinfra.com/v1/openai", model: "openai/whisper-large-v3-turbo"),
        .init(name: "Fireworks", baseURL: "https://api.fireworks.ai/inference/v1", model: "whisper-v3-turbo"),
        .init(name: "Lemonfox", baseURL: "https://api.lemonfox.ai/v1", model: "whisper-1"),
        .init(name: "Mistral (Voxtral)", baseURL: "https://api.mistral.ai/v1", model: "voxtral-mini-transcribe-26-02"),
        .init(name: "Zhipu GLM (International)", baseURL: "https://api.z.ai/api/paas/v4", model: "glm-asr-2512"),
        .init(name: "Zhipu GLM (China)", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-asr-2512"),
        .init(name: "Local server", baseURL: "http://192.168.1.10:8080/v1", model: "whisper-1"),
    ]

    /// Only for providers that are *not* first-class backends — anything with
    /// its own `PolishBackendSpec` has its own key slot and model field, which
    /// a base-URL preset would quietly bypass.
    static let polish: [ProviderPreset] = [
        .init(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-5.6-luna"),
        .init(name: "Cerebras", baseURL: "https://api.cerebras.ai/v1", model: "llama3.1-8b"),
        .init(name: "Together", baseURL: "https://api.together.xyz/v1", model: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
        .init(name: "Fireworks", baseURL: "https://api.fireworks.ai/inference/v1", model: "accounts/fireworks/models/llama-v3p3-70b-instruct"),
        .init(name: "Local server", baseURL: "http://192.168.1.10:8080/v1", model: "local-model"),
    ]
}

enum SettingsStore {
    private static let key = "settings.providers"

    static func load() -> ProviderSettings {
        guard let data = AppGroup.defaults?.data(forKey: key),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else { return ProviderSettings() }
        return settings
    }

    static func save(_ settings: ProviderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        AppGroup.defaults?.set(data, forKey: key)
    }
}
