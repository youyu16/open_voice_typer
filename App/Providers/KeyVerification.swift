import CryptoKit
import Foundation

/// Verifies an API key with a free request (list-models) so users know a key
/// works before dictating with it.
enum KeyVerifier {
    /// Which provider surface a key belongs to, and how to ping it.
    enum Target {
        case openAICompatible(baseURL: String)
        case anthropic
        case gemini

        /// The host this backend's requests connect to. Verification already
        /// has to know it, so connection warming reads it from here rather
        /// than making every `PolishBackendSpec` repeat its endpoint.
        var origin: URL? {
            switch self {
            case .openAICompatible(let baseURL):
                ConnectionWarmer.origin(ofBaseURL: baseURL)
            case .anthropic:
                URL(string: "https://api.anthropic.com/")
            case .gemini:
                URL(string: "https://generativelanguage.googleapis.com/")
            }
        }
    }

    static func verify(key: String, target: Target) async throws {
        var request: URLRequest
        switch target {
        case .openAICompatible(let baseURL):
            let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard let url = URL(string: "\(base)/models") else {
                throw PolishError.invalidBaseURL(baseURL)
            }
            request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PolishError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }
}

/// Remembers which exact key value was last verified per Keychain slot, so
/// the UI can show ✓ Verified without pinging providers on every visit.
/// Only a SHA-256 fingerprint is stored, never the key.
enum KeyStatusStore {
    enum Status {
        case missing
        case unverified
        case verified
    }

    static func status(for key: KeychainStore.Key) -> Status {
        guard let secret = KeychainStore.get(key) else { return .missing }
        return UserDefaults.standard.string(forKey: defaultsKey(key)) == fingerprint(secret)
            ? .verified
            : .unverified
    }

    static func markVerified(_ key: KeychainStore.Key) {
        guard let secret = KeychainStore.get(key) else { return }
        UserDefaults.standard.set(fingerprint(secret), forKey: defaultsKey(key))
    }

    static func clear(_ key: KeychainStore.Key) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(key))
    }

    private static func defaultsKey(_ key: KeychainStore.Key) -> String {
        "keyVerified.\(key.rawValue)"
    }

    private static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
