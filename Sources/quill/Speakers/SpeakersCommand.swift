import ArgumentParser
import Foundation

/// Inspect and curate the voice library from the terminal — and backfill it
/// from meetings recorded before diarization existed, which is what makes
/// cross-meeting identity useful on day one instead of in a month.
struct Speakers: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, name, and backfill known speakers."
    )

    @Flag(name: .long, help: "Re-run diarization and name inference over existing recordings.")
    var backfill: Bool = false

    @Option(name: .long, help: "Rename a voice: --name <voice-id>=<name>.")
    var name: String?

    @Option(name: .long, help: "Recordings root (defaults to config).")
    var out: String?

    func run() throws {
        if let name {
            try rename(spec: name)
            return
        }
        if backfill {
            try runBackfill()
            return
        }
        list()
    }

    // MARK: -

    private func list() {
        let library = SpeakerLibrary.load()
        guard !library.voices.isEmpty else {
            print("no voices yet — record a meeting with diarization enabled")
            return
        }
        print("\(library.voices.count) voice(s) — \(SpeakerLibrary.path.path)\n")
        for voice in library.voices.sorted(by: { $0.totalSeconds > $1.totalSeconds }) {
            let minutes = Int(voice.totalSeconds / 60)
            let label = voice.name ?? voice.suggestedName.map { "\($0)?" } ?? "unnamed"
            print("  \(voice.id.prefix(8))  \(label)")
            print("      \(minutes)m across \(voice.meetings.count) meeting(s)")
            if voice.name == nil, !voice.nameEvidence.isEmpty {
                let ranked = voice.nameEvidence
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { "\($0.key) (\(String(format: "%.1f", $0.value)))" }
                print("      heard as: \(ranked.joined(separator: ", "))")
            }
        }
        print("\nname one with:  quill speakers --name <id>=<name>")
    }

    private func rename(spec: String) throws {
        let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            FileHandle.standardError.write(Data("expected --name <voice-id>=<name>\n".utf8))
            throw ExitCode(64)
        }
        var library = SpeakerLibrary.load()
        // Accept an id prefix so you can copy the short form from the list.
        guard let voice = library.voices.first(where: { $0.id.hasPrefix(parts[0]) }) else {
            FileHandle.standardError.write(Data("no voice matching \"\(parts[0])\"\n".utf8))
            throw ExitCode(1)
        }
        library.rename(id: voice.id, to: parts[1])
        library.save()
        print("✓ \(voice.id.prefix(8)) is now \(parts[1])")

        // Materialize the name in every transcript that voice appears in.
        let root = Config.resolveRoot(cliOverride: out)
        var updated = 0
        for meeting in voice.meetings {
            let dir = root.appendingPathComponent(meeting, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            Transcript.relabel(dir: dir, using: library)
            updated += 1
        }
        print("  relabeled \(updated) transcript(s)")
    }

    /// Diarize already-transcribed sessions oldest-first, so the library
    /// learns voices (and names spoken in those meetings) from history.
    /// Re-running is safe: matching is by voice, so the same person
    /// accumulates rather than duplicating.
    private func runBackfill() throws {
        let root = Config.resolveRoot(cliOverride: out)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            FileHandle.standardError.write(Data("can't read \(root.path)\n".utf8))
            throw ExitCode(1)
        }

        let sessions = entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path) }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("system.caf").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !sessions.isEmpty else {
            print("no transcribed sessions with a system track under \(root.path)")
            return
        }
        print("backfilling \(sessions.count) session(s) — this runs the diarizer on each\n")

        let coordinator = TranscriptionCoordinator()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            for dir in sessions {
                print("  \(dir.lastPathComponent)…")
                await coordinator.redoSpeakers(in: dir)
            }
            semaphore.signal()
        }
        semaphore.wait()

        print("")
        list()
    }
}
