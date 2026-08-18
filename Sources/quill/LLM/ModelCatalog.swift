import Foundation

/// The models quill knows how to set up, smallest first.
///
/// Weights are never vendored: the 8B is 5.2 GB, two orders of magnitude past
/// GitHub's per-file limit, and redistribution terms vary by model. What ships
/// in the repo is the *recipe* — plus Apple's built-in model, which needs no
/// download because it comes with the OS.
struct ModelOption: Sendable {
    let id: String
    let label: String
    /// Download size in GB; 0 for the built-in model.
    let gigabytes: Double
    /// Rough floor for comfortable use, in GB of system memory.
    let requiresMemoryGB: Double
    let blurb: String

    var isBuiltIn: Bool { id == "apple" }
    var isOff: Bool { id == "none" }

    var sizeText: String {
        isBuiltIn || isOff ? "no download" : String(format: "%.1f GB", gigabytes)
    }
}

enum ModelCatalog {
    static let options: [ModelOption] = [
        ModelOption(
            id: "none", label: "Off", gigabytes: 0, requiresMemoryGB: 0,
            blurb: "No notes, no summaries — transcripts only."
        ),
        ModelOption(
            id: "apple", label: "Built-in (Apple)", gigabytes: 0, requiresMemoryGB: 0,
            blurb: "Ships with macOS 26. Instant, private, but a small context window: "
                + "long meetings are summarized in pieces and read noticeably weaker."
        ),
        ModelOption(
            id: "qwen3:4b", label: "Small (Qwen3 4B)", gigabytes: 2.6, requiresMemoryGB: 8,
            blurb: "Good notes on a modest machine."
        ),
        ModelOption(
            id: "qwen3:8b", label: "Balanced (Qwen3 8B)", gigabytes: 5.2, requiresMemoryGB: 16,
            blurb: "Recommended. Reads a whole meeting at once; notes cite real numbers."
        ),
        ModelOption(
            id: "qwen3:14b", label: "Large (Qwen3 14B)", gigabytes: 9.3, requiresMemoryGB: 32,
            blurb: "Sharper summaries and better speaker guesses; slower."
        ),
        ModelOption(
            id: "qwen3:30b-a3b", label: "Very large (Qwen3 30B MoE)", gigabytes: 18.6,
            requiresMemoryGB: 48,
            blurb: "Best quality here; only sensible with lots of memory."
        ),
    ]

    static func option(id: String) -> ModelOption? {
        options.first { $0.id == id }
    }

    static var memoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// Largest option this machine can comfortably run — what the menu marks
    /// as recommended and what `quill models` suggests.
    static var recommended: ModelOption {
        let memory = memoryGB
        return options.last { !$0.isOff && !$0.isBuiltIn && $0.requiresMemoryGB <= memory }
            ?? options[1]
    }

    /// The option currently in effect, derived from config.
    static var active: ModelOption {
        switch Config.llmProvider() {
        case "none": return options[0]
        case "apple": return options[1]
        default: return option(id: Config.llmModel())
            ?? ModelOption(
                id: Config.llmModel(), label: Config.llmModel(), gigabytes: 0,
                requiresMemoryGB: 0, blurb: "configured manually"
            )
        }
    }
}
