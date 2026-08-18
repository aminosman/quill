import Foundation

/// Talks to a local Ollama server. Structured output uses Ollama's `format`
/// field (a JSON schema), which constrains decoding rather than merely asking
/// nicely — so the reply parses on the first try.
struct OllamaEngine: LLMEngine {
    let model: String
    let host: String

    var name: String { "ollama:\(model)" }
    /// Deliberately conservative against the configured context window: a
    /// whole hour-long transcript fits, and overshooting silently truncates
    /// the *start* of the conversation, which is where introductions live.
    var contextCharacters: Int { Config.llmContextTokens() * 3 }

    func isReachable() async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return false }
        // A configured model that isn't pulled would fail on every call.
        let names = models.compactMap { $0["name"] as? String }
        return names.contains { $0 == model || $0.hasPrefix(model + ":") }
    }

    func respond(system: String, prompt: String, schema: JSONSchema) async throws -> String {
        guard let url = URL(string: "\(host)/api/chat") else {
            throw LLMError.unavailable("bad host \(host)")
        }
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            // Qwen-style reasoning models otherwise spend minutes thinking
            // before answering; quill wants the extraction, not the monologue.
            "think": false,
            "format": schema.jsonObject,
            "options": [
                "temperature": 0,
                "num_ctx": Config.llmContextTokens(),
            ],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = Config.llmTimeoutSeconds()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.requestFailed(String(data: data, encoding: .utf8) ?? "http error")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw LLMError.requestFailed("unexpected response shape") }
        return content
    }
}
