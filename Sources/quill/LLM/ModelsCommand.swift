import ArgumentParser
import Foundation

/// Pick the model that writes meeting notes, and set it up in one step.
struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, install, and choose the local model used for meeting notes."
    )

    @Option(name: .long, help: "Install and switch to a model id (e.g. qwen3:8b, apple, none).")
    var use: String?

    func run() throws {
        if let use {
            guard let option = ModelCatalog.option(id: use) ?? passthrough(use) else {
                FileHandle.standardError.write(Data("unknown model \"\(use)\"\n".utf8))
                throw ExitCode(64)
            }
            let semaphore = DispatchSemaphore(value: 0)
            ModelInstaller.activate(option) { progress in
                switch progress {
                case .message(let text): print("  \(text)")
                case .downloading(let percent): print("  downloading… \(percent)%")
                case .done(let text): print("✓ \(text)"); semaphore.signal()
                case .failed(let text): print("✗ \(text)"); semaphore.signal()
                }
            }
            semaphore.wait()
            return
        }
        list()
    }

    /// Allow any Ollama tag, not just the curated list.
    private func passthrough(_ id: String) -> ModelOption? {
        guard id.contains(":") else { return nil }
        return ModelOption(
            id: id, label: id, gigabytes: 0, requiresMemoryGB: 0, blurb: "custom Ollama model"
        )
    }

    private func list() {
        let installed = Set(
            ModelInstaller.ollamaPath().map(ModelInstaller.installedModels(ollama:)) ?? []
        )
        let active = ModelCatalog.active
        let recommended = ModelCatalog.recommended
        print(String(format: "this Mac has %.0f GB of memory\n", ModelCatalog.memoryGB))

        for option in ModelCatalog.options {
            var marks: [String] = []
            if option.id == active.id { marks.append("active") }
            if option.id == recommended.id { marks.append("recommended") }
            if installed.contains(option.id) { marks.append("downloaded") }
            if !option.isOff, !option.isBuiltIn, option.requiresMemoryGB > ModelCatalog.memoryGB {
                marks.append("needs \(Int(option.requiresMemoryGB)) GB RAM")
            }
            let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]"
            print("  \(option.id.padding(toLength: 16, withPad: " ", startingAt: 0)) "
                + "\(option.sizeText.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + "\(option.label)\(suffix)")
            print("      \(option.blurb)")
        }
        print("\nswitch with:  quill models --use \(recommended.id)")
        print("(downloads and configures everything; also in the menu bar under Meeting notes)")
    }
}
