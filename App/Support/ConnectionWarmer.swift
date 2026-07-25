import Foundation

/// Opens a connection to a provider host *before* the request that needs it.
///
/// A dictation's first network call otherwise pays DNS + TCP + TLS on the
/// critical path — a couple of hundred milliseconds on Wi-Fi, often more than
/// a second on cellular — and it pays it after the user has stopped speaking,
/// where the wait is felt. Recording is a free window: the moment the user
/// starts talking we already know which hosts the transcript will visit, so
/// the handshake happens while they speak and the real POST reuses the pooled
/// connection.
///
/// Warm requests are unauthenticated and their responses are discarded; the
/// only thing being kept is the connection URLSession leaves in its pool.
actor ConnectionWarmer {
    static let shared = ConnectionWarmer()

    /// A pooled connection outlives this comfortably, so re-warming a host
    /// warmed a moment ago would be noise (and an extra request per dictation
    /// for a user who dictates in bursts).
    private static let reuseWindow: TimeInterval = 45
    /// A warm-up must never outlive the dictation it was meant to help.
    private static let timeout: TimeInterval = 5

    private let session: URLSession
    private var lastWarmed: [URL: Date] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fire-and-forget: returns as soon as the handshakes are in flight.
    /// `nil` entries (an unusable base URL) are ignored — a warm-up is an
    /// optimization, never a source of errors.
    func warm(_ origins: [URL?]) {
        let now = Date.now
        for origin in origins.compactMap({ $0 }) {
            if let last = lastWarmed[origin], now.timeIntervalSince(last) < Self.reuseWindow {
                continue
            }
            lastWarmed[origin] = now

            var request = URLRequest(url: origin)
            request.httpMethod = "HEAD"
            request.timeoutInterval = Self.timeout
            // Whatever the host answers — 200, 404, 405 — the connection is up
            // by the time it does, which is the entire point.
            session.dataTask(with: request) { _, _, _ in }.resume()
        }
    }

    /// `scheme://host[:port]/` for an API base URL, which is the granularity
    /// URLSession pools connections at. Nil when the string isn't a usable
    /// absolute URL.
    nonisolated static func origin(ofBaseURL baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme,
              let host = url.host()
        else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }
}
