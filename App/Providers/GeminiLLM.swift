import Foundation

/// Polish via the Google Gemini API (`models/{model}:generateContent`).
struct GeminiLLM: PolishProvider {
    var model: String = "gemini-3.5-flash-lite"
    var apiKey: @Sendable () -> String?
    var session: URLSession = .shared

    struct Body: Encodable {
        struct Part: Encodable { let text: String }
        struct Content: Encodable {
            var role: String?
            let parts: [Part]
        }
        /// Both generations put their thinking control inside `thinkingConfig`
        /// — the level did not replace the object, only the field inside it.
        /// Sending both in one request is rejected.
        struct GenerationConfig: Encodable {
            struct ThinkingConfig: Encodable {
                /// Gemini 3.x: "minimal" | "low" | "medium" | "high".
                var thinkingLevel: String?
                /// Gemini 2.5: a token budget, 0 to turn thinking off.
                var thinkingBudget: Int?
            }
            let thinkingConfig: ThinkingConfig
        }
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: GenerationConfig?

        enum CodingKeys: String, CodingKey {
            case systemInstruction = "system_instruction"
            case contents
            case generationConfig
        }
    }

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

    func polish(_ request: PolishRequest) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw PolishError.missingAPIKey }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw PolishError.invalidBaseURL(model)
        }

        let system = Body.Content(role: nil, parts: [.init(text: PromptBuilder.systemPrompt(for: request))])
        let contents = [Body.Content(role: "user", parts: [.init(text: request.transcript)])]

        func send(thinking: Body.GenerationConfig?) async throws -> String {
            try await PolishHTTP.post(
                url,
                body: Body(systemInstruction: system, contents: contents, generationConfig: thinking),
                headers: ["x-goog-api-key": key],
                session: session,
                as: GenerateResponse.self
            ) { response in
                (response.candidates?.first?.content?.parts ?? []).compactMap(\.text).joined()
            }
        }

        guard let thinking = Self.thinkingConfig(for: model) else {
            return try await send(thinking: nil)
        }
        do {
            return try await send(thinking: thinking)
        } catch let PolishError.http(status, body) where status == 400 && Self.isThinkingFieldRejection(body) {
            // Turning thinking off is an optimization; it must never be the
            // reason a dictation fails. Google has moved this field once
            // already (2.5's budget → 3.x's level), and a rejected field
            // shape is recoverable: send the same request without it and the
            // user gets their text, just a little slower.
            return try await send(thinking: nil)
        }
    }

    // MARK: Thinking

    /// Polish reshapes a transcript, it never reasons about one, so every
    /// second spent thinking is latency the user feels for output they can't
    /// tell apart. Nil means "leave this model on its defaults".
    static func thinkingConfig(for model: String) -> Body.GenerationConfig? {
        let name = model.lowercased()
        // 3.x replaced the token budget with a level, and takes one on every
        // model — Pro included, with no floor to trip over.
        if name.hasPrefix("gemini-3") {
            return .init(thinkingConfig: .init(thinkingLevel: "minimal"))
        }
        // 2.5 accepts a zero budget on Flash only: Pro has a floor, and the
        // non-thinking models reject the field outright.
        if name.contains("2.5-flash") {
            return .init(thinkingConfig: .init(thinkingBudget: 0))
        }
        return nil
    }

    /// Whether a 400 is Google objecting to the thinking field specifically,
    /// rather than to something we'd only mask by retrying — a bad key, a
    /// malformed prompt, a model that doesn't exist.
    static func isThinkingFieldRejection(_ body: String) -> Bool {
        let body = body.lowercased()
        return body.contains("thinkinglevel")
            || body.contains("thinking_level")
            || body.contains("thinkingbudget")
            || body.contains("thinking_budget")
            || body.contains("thinkingconfig")
            || body.contains("thinking_config")
    }
}
