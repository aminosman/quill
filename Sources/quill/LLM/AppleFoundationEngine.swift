import Foundation
import FoundationModels

/// Apple's on-device Foundation model. Gated to macOS 26 so quill still
/// builds and runs on 15 — there it simply reports itself unavailable. Nothing to install and nothing leaves
/// the machine, at the cost of a 4096-token context — small enough that quill
/// summarizes long meetings in pieces when this is the active provider.
@available(macOS 26.0, *)
struct AppleFoundationEngine: LLMEngine {
    var name: String { "apple-foundation" }
    /// ~4096 tokens total for prompt *and* reply; leave the reply room.
    var contextCharacters: Int { 6_000 }

    static func ifAvailable() -> AppleFoundationEngine? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return AppleFoundationEngine()
    }

    func respond(system: String, prompt: String, schema: JSONSchema) async throws -> String {
        // This provider has no schema-constrained decoding for dynamic shapes,
        // so the schema is described in the instructions and the reply is
        // parsed leniently by the caller.
        let instructions = """
        \(system)

        Reply with JSON only — no prose, no code fences — with exactly these keys:
        \(schema.described)
        """
        var options = GenerationOptions(sampling: .greedy)
        options.temperature = 0
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        } catch {
            throw LLMError.requestFailed("\(error)")
        }
    }
}
