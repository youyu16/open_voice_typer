import Foundation
import Security

/// API keys live here and are only ever read by the main app — the keyboard
/// extension has no access (separate keychain, and it never needs keys).
enum KeychainStore {
    static let service = "com.shuaiwang.openvoicetyper"

    enum Key: String, CaseIterable {
        case asrAPIKey = "asr.apiKey"
        case asrElevenLabsKey = "asr.elevenlabs.apiKey"
        case polishOpenAIKey = "polish.openaiCompatible.apiKey"
        case polishDeepSeekKey = "polish.deepseek.apiKey"
        case polishAnthropicKey = "polish.anthropic.apiKey"
        case polishGeminiKey = "polish.gemini.apiKey"
        case polishGroqKey = "polish.groq.apiKey"
        case polishOpenRouterKey = "polish.openrouter.apiKey"
        case polishXAIKey = "polish.xai.apiKey"
        case polishMistralKey = "polish.mistral.apiKey"
    }

    static func set(_ value: String, for key: Key) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(key)
            return
        }
        let data = Data(trimmed.utf8)
        var query = baseQuery(for: key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        } else {
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func get(_ key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func delete(_ key: Key) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private static func baseQuery(for key: Key) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
        ]
    }
}
