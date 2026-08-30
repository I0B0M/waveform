import Foundation
import Security

/// Optional bigger brain for AI MODE, on the user's own Claude API key.
///
/// The contract that keeps the app honest: on-device is the default and the
/// brand. The cloud path is strictly opt-in, used ONLY for compose (AI mode
/// and reply-to-selection), and sends text only — the transcribed
/// instruction, the selection, and the context block (app name, window
/// title, text around the cursor). Audio never leaves the Mac, dictation
/// itself never leaves the Mac, and secure-field sessions never reach here
/// (they carry no context and no selection by construction).
///
/// The key lives in the Keychain — never in UserDefaults, never in a file.
enum CloudBrain {
    enum CloudError: LocalizedError {
        case noKey
        case badStatus(Int, String)
        case refused(String?)
        case emptyReply

        var errorDescription: String? {
            switch self {
            case .noKey: return "No API key configured."
            case .badStatus(let code, let body): return "Claude API error \(code): \(body)"
            case .refused(let category): return "The request was declined (\(category ?? "safety"))."
            case .emptyReply: return "The model returned no text."
            }
        }
    }

    // MARK: - Keychain

    private static let service = "com.ibrahim.waveform"
    private static let account = "anthropic-api-key"

    static var isConfigured: Bool { loadKey() != nil }

    static func saveKey(_ key: String) {
        deleteKey()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func loadKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    // MARK: - The one call

    /// POST /v1/messages with the compose instruction. Swift has no official
    /// SDK, so this is the documented raw-HTTP shape. Uses claude-opus-5 with
    /// server-side refusal fallbacks enabled (routes a declined request to a
    /// fallback model automatically) and low effort — compose outputs are
    /// short and latency matters at the cursor.
    static func compose(instructions: String, prompt: String) async throws -> String {
        guard let key = loadKey() else { throw CloudError.noKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 1024,
            "system": instructions,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "messages": [
                ["role": "user", "content": prompt]
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.emptyReply }
        guard http.statusCode == 200 else {
            let bodyText = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw CloudError.badStatus(http.statusCode, bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.emptyReply
        }
        if let stopReason = json["stop_reason"] as? String, stopReason == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw CloudError.refused(details?["category"] as? String)
        }
        guard let content = json["content"] as? [[String: Any]] else { throw CloudError.emptyReply }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CloudError.emptyReply }
        return text
    }
}
