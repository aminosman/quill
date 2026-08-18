import Foundation

/// A local language model, behind one small interface so the rest of quill
/// never cares which one is running.
///
/// Two providers ship, chosen by capability rather than preference:
///
///   * **apple** — Apple's on-device Foundation model. Free, already
///     installed on macOS 26 with Apple Intelligence, no download, no extra
///     process. It has a hard 4096-token context, so long transcripts must be
///     summarized in pieces and stitched.
///   * **ollama** — any local model served by Ollama. Measured on real
///     meetings, an 8B model reads a whole 30k-character transcript in one
///     pass and writes notes that name real numbers and commitments, where
///     the 3B model's chunked pass produced small talk and "S1: Yes." as a
///     decision. Costs a ~5 GB download and ~8 GB of RAM.
///
/// Nothing here reaches the network beyond localhost.
protocol LLMEngine: Sendable {
    var name: String { get }
    /// Roughly how much text fits in one request, in characters.
    var contextCharacters: Int { get }
    /// Ask for JSON matching `schema` and return the raw JSON text.
    func respond(system: String, prompt: String, schema: JSONSchema) async throws -> String
}

/// Minimal JSON-schema builder — enough to describe the flat objects quill
/// asks for, in the shape both providers accept.
struct JSONSchema: Sendable {
    enum Field: Sendable {
        case string(description: String)
        case stringArray(description: String)
    }

    let fields: [(name: String, field: Field)]

    init(_ fields: [(String, Field)]) {
        self.fields = fields.map { (name: $0.0, field: $0.1) }
    }

    var jsonObject: [String: Any] {
        var properties: [String: Any] = [:]
        for entry in fields {
            switch entry.field {
            case .string(let description):
                properties[entry.name] = ["type": "string", "description": description]
            case .stringArray(let description):
                properties[entry.name] = [
                    "type": "array",
                    "description": description,
                    "items": ["type": "string"],
                ]
            }
        }
        return [
            "type": "object",
            "properties": properties,
            "required": fields.map(\.name),
        ]
    }

    /// Prose rendering, for providers that take instructions rather than a
    /// schema object.
    var described: String {
        fields.map { entry in
            switch entry.field {
            case .string(let description): return "\"\(entry.name)\": string — \(description)"
            case .stringArray(let description): return "\"\(entry.name)\": array of strings — \(description)"
            }
        }.joined(separator: "\n")
    }
}

enum LLMError: Error, CustomStringConvertible {
    case unavailable(String)
    case requestFailed(String)

    var description: String {
        switch self {
        case .unavailable(let why): return "no local model available: \(why)"
        case .requestFailed(let why): return "model request failed: \(why)"
        }
    }
}

/// Pick a provider from config, falling back down the ladder so a machine
/// without Ollama still gets what Apple's model can do, and a machine without
/// either simply skips the LLM features instead of erroring.
enum LLMFactory {
    static func make() async -> LLMEngine? {
        switch Config.llmProvider() {
        case "none":
            return nil
        case "ollama":
            return await ollamaIfReachable()
        case "apple":
            return appleIfAvailable()
        default:
            // "auto": prefer the bigger local model when it's actually
            // running, else Apple's built-in, else nothing.
            if let ollama = await ollamaIfReachable() { return ollama }
            return appleIfAvailable()
        }
    }

    private static func appleIfAvailable() -> LLMEngine? {
        guard #available(macOS 26.0, *) else { return nil }
        return AppleFoundationEngine.ifAvailable()
    }

    private static func ollamaIfReachable() async -> LLMEngine? {
        let engine = OllamaEngine(model: Config.llmModel(), host: Config.llmHost())
        return await engine.isReachable() ? engine : nil
    }
}
