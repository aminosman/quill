import Foundation

/// Gets a chosen model actually running: installs Ollama if needed, starts the
/// server, pulls the weights with progress, and writes the config. The point
/// is that picking a model in the menu is the only step a user performs.
/// Rate-limits progress reporting to one notification per 10% step.
private final class Milestone: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func advance(to percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent / 10 != last / 10 else { return false }
        last = percent
        return true
    }
}

enum ModelInstaller {
    enum Progress: Sendable {
        case message(String)
        case downloading(percent: Int)
        case done(String)
        case failed(String)
    }

    /// Switch to `option`, downloading whatever it needs. `report` is called
    /// on a background thread as things happen.
    static func activate(_ option: ModelOption, report: @escaping @Sendable (Progress) -> Void) {
        if option.isOff {
            Config.setLLM(provider: "none", model: nil)
            report(.done("Meeting notes turned off"))
            return
        }
        if option.isBuiltIn {
            Config.setLLM(provider: "apple", model: nil)
            report(.done("Using the built-in Apple model"))
            return
        }

        guard let ollama = ensureOllama(report: report) else {
            report(.failed(
                "Ollama isn't installed. Install Homebrew and run: brew install ollama"
            ))
            return
        }
        ensureServer(ollama: ollama, report: report)

        if installedModels(ollama: ollama).contains(where: { $0 == option.id }) {
            Config.setLLM(provider: "ollama", model: option.id)
            report(.done("\(option.label) ready"))
            return
        }

        report(.message("Downloading \(option.label) — \(option.sizeText)"))
        let pull = Process()
        pull.executableURL = URL(fileURLWithPath: ollama)
        pull.arguments = ["pull", option.id]
        let pipe = Pipe()
        pull.standardOutput = pipe
        pull.standardError = pipe

        // The readability handler runs on its own queue; a lock keeps the
        // last-reported milestone consistent without an actor.
        let milestone = Milestone()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            // Ollama redraws a progress line; pull the last percentage out.
            for token in text.split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\n" })
            where token.hasSuffix("%") {
                if let percent = Int(token.dropLast()), milestone.advance(to: percent) {
                    report(.downloading(percent: percent))
                }
            }
        }
        do {
            try pull.run()
        } catch {
            report(.failed("couldn't start ollama pull: \(error)"))
            return
        }
        pull.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        guard pull.terminationStatus == 0 else {
            report(.failed("download failed (exit \(pull.terminationStatus))"))
            return
        }
        Config.setLLM(provider: "ollama", model: option.id)
        report(.done("\(option.label) ready"))
    }

    // MARK: - Ollama plumbing

    static func ollamaPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/ollama").path,
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func ensureOllama(report: @escaping @Sendable (Progress) -> Void) -> String? {
        if let existing = ollamaPath() { return existing }
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let brew else { return nil }

        report(.message("Installing Ollama (one time)…"))
        let install = Process()
        install.executableURL = URL(fileURLWithPath: brew)
        install.arguments = ["install", "ollama"]
        install.standardOutput = Pipe()
        install.standardError = Pipe()
        try? install.run()
        install.waitUntilExit()
        return ollamaPath()
    }

    /// The server has to be listening for quill to use it, and it should come
    /// back after a reboot — `brew services` when available, a detached
    /// process otherwise.
    private static func ensureServer(ollama: String, report: @escaping @Sendable (Progress) -> Void) {
        if isServerUp() { return }
        report(.message("Starting the model server…"))
        if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let services = Process()
            services.executableURL = URL(fileURLWithPath: brew)
            services.arguments = ["services", "start", "ollama"]
            services.standardOutput = Pipe()
            services.standardError = Pipe()
            try? services.run()
            services.waitUntilExit()
        }
        if !isServerUp() {
            let serve = Process()
            serve.executableURL = URL(fileURLWithPath: ollama)
            serve.arguments = ["serve"]
            serve.standardOutput = FileHandle.nullDevice
            serve.standardError = FileHandle.nullDevice
            try? serve.run()
        }
        for _ in 0..<20 where !isServerUp() {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    static func isServerUp() -> Bool {
        guard let url = URL(string: Config.llmHost() + "/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var up = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            up = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return up
    }

    static func installedModels(ollama: String) -> [String] {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: ollama)
        list.arguments = ["list"]
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = Pipe()
        guard (try? list.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        list.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .dropFirst()
            .compactMap { $0.split(separator: " ").first.map(String.init) }
    }
}
