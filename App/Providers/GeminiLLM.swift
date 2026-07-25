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
                struct ThinkingConfig: Encodable { let thinkingBudget: Int }
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
        let body = Body(
            systemInstruction: .init(role: nil, parts: [.init(text: PromptBuilder.systemPrompt(for: request))]),
            contents: [.init(role: "user", parts: [.init(text: request.transcript)])],
            generationConfig: Self.acceptsZeroThinkingBudget(model)
                ? .init(thinkingConfig: .init(thinkingBudget: 0))
                : nil
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

    /// Gemini's 2.5 Flash models think before answering by default, which adds
    /// seconds and tokens to what is a mechanical rewrite — polish reshapes a
    /// transcript, it never reasons about it. Only the Flash family accepts a
    /// zero budget (Pro has a floor, and non-thinking models reject the field
    /// outright), so anything else is left on its defaults rather than risking
    /// a 400 on a model we don't recognize.
    static func acceptsZeroThinkingBudget(_ model: String) -> Bool {
        model.lowercased().contains("2.5-flash")
    }
}
