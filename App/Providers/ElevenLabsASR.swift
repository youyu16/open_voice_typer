import Foundation

/// Transcription via ElevenLabs Scribe: `POST /v1/speech-to-text`.
///
/// Not an OpenAI-compatible endpoint, which is the whole reason it needs its
/// own client: a different path, a different auth header (`xi-api-key`, not
/// `Bearer`), a different field name for the model (`model_id`), and a
/// response carrying detected language and per-word timings alongside the
/// text. A base-URL preset could never have reached it.
struct ElevenLabsASR: ASRProvider {
    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    var model: String = "scribe_v1"
    var apiKey: @Sendable () -> String?
    var session: URLSession = .shared

    func transcribe(_ request: ASRRequest) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw ASRError.missingAPIKey }

        var form = MultipartForm()
        form.addFile(name: "file", filename: "audio.wav", contentType: "audio/wav", data: request.wavData)
        form.addField(name: "model_id", value: model)
        if !request.language.isEmpty {
            form.addField(name: "language_code", value: request.language)
        }
        // Scribe annotates non-speech sounds — "(laughter)", "(footsteps)" —
        // and defaults to doing so. That is transcription of a recording, not
        // dictation: nobody wants "(clears throat)" typed into their message.
        form.addField(name: "tag_audio_events", value: "false")
        // `hotwords` are deliberately unused: Scribe has no term-biasing field
        // on this endpoint. The dictionary still reaches the transcript
        // through the polish prompt, which spells its terms exactly.

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue(form.contentTypeHeader, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.encode()

        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ASRError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }

        struct ScribeResponse: Decodable { let text: String? }
        let text = (try JSONDecoder().decode(ScribeResponse.self, from: data).text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ASRError.emptyTranscript }
        return text
    }
}
