import Foundation

/// Polish via the Google Gemini API (`models/{model}:generateContent`).
struct GeminiLLM: PolishProvider {
    var model: String = "gemini-2.5-flash"
    var apiKey: @Sendable () -> String?
    var session: URLSession = .shared

    func polish(_ request: PolishRequest) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw PolishError.missingAPIKey }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw PolishError.invalidBaseURL(model)
        }

        struct Body: Encodable {
            struct Part: Encodable { let text: String }
            struct Content: Encodable {
                var role: String?
                let parts: [Part]
            }
            struct GenerationConfig: Encodable {
                struct ThinkingConfig: Encodable {
                    let thinkingBudget: Int

                    enum CodingKeys: String, CodingKey {
                        case thinkingBudget = "thinking_budget"
                    }
                }
                /// Gemini 3.x
                var thinkingLevel: String?
                /// Gemini 2.5
                var thinkingConfig: ThinkingConfig?

                enum CodingKeys: String, CodingKey {
                    case thinkingLevel = "thinking_level"
                    case thinkingConfig = "thinking_config"
                }
            }
            let systemInstruction: Content
            let contents: [Content]
            let generationConfig: GenerationConfig?

            enum CodingKeys: String, CodingKey {
                case systemInstruction = "system_instruction"
                case contents
                case generationConfig = "generation_config"
            }
        }
        let body = Body(
            systemInstruction: .init(role: nil, parts: [.init(text: PromptBuilder.systemPrompt(for: request))]),
            contents: [.init(role: "user", parts: [.init(text: request.transcript)])],
            generationConfig: {
                switch Self.thinkingControl(for: model) {
                case .level(let level): .init(thinkingLevel: level)
                case .zeroBudget: .init(thinkingConfig: .init(thinkingBudget: 0))
                case .unsupported: nil
                }
            }()
        )

        struct GenerateResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        return try await PolishHTTP.post(
            url,
            body: body,
            headers: ["x-goog-api-key": key],
            session: session,
            as: GenerateResponse.self
        ) { response in
            (response.candidates?.first?.content?.parts ?? []).compactMap(\.text).joined()
        }
    }

    /// How to tell a given Gemini model to stop thinking. Polish reshapes a
    /// transcript, it never reasons about one, so every second spent thinking
    /// is latency the user feels for output they can't tell apart.
    enum ThinkingControl: Equatable {
        /// Gemini 3.x: `thinking_level`, which replaced the token budget.
        case level(String)
        /// Gemini 2.5: `thinking_config.thinking_budget = 0`.
        case zeroBudget
        /// Leave the model on its defaults.
        case unsupported
    }

    /// The two generations spell this differently, and sending the wrong one is
    /// a 400 — so the dialect is chosen per model family, and an unrecognized
    /// model is left alone rather than guessed at. (This is why the check can't
    /// just be "is it a Flash model": a 3.x model given a `thinking_budget`
    /// silently kept thinking, because the field no longer exists there.)
    static func thinkingControl(for model: String) -> ThinkingControl {
        let name = model.lowercased()
        // 3.x takes a level on every model, Pro included — no floor to trip over.
        if name.hasPrefix("gemini-3") { return .level("minimal") }
        // 2.5 accepts a zero budget on Flash only: Pro has a floor, and the
        // non-thinking models reject the field outright.
        if name.contains("2.5-flash") { return .zeroBudget }
        return .unsupported
    }
}
