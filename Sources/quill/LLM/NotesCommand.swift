import ArgumentParser
import Foundation

/// Write meeting notes for recordings that don't have them yet — the same
/// pass the daemon runs after each meeting, applied to your back catalogue.
struct Notes: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate summary.md for transcribed recordings using the local model."
    )

    @Flag(name: .long, help: "Rewrite notes even where summary.md already exists.")
    var force: Bool = false

    @Option(name: .long, help: "Only this session (folder name).")
    var session: String?

    @Option(name: .long, help: "Recordings root (defaults to config).")
    var out: String?

    func run() throws {
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
            .filter { session == nil || $0.lastPathComponent == session }
            .filter { force || !fm.fileExists(atPath: $0.appendingPathComponent("summary.md").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard !sessions.isEmpty else {
            print("nothing to do — every transcribed session already has notes")
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            guard let engine = await LLMFactory.make() else {
                FileHandle.standardError.write(Data(
                    "no local model reachable — run `quill doctor` for setup\n".utf8
                ))
                semaphore.signal()
                return
            }
            print("writing notes for \(sessions.count) session(s) with \(engine.name)\n")
            let projects = Project.enabled(in: Config.projectsDir())
                .map { (name: $0.name, description: $0.description) }

            for dir in sessions {
                guard let transcript = Transcript.read(from: dir), !transcript.segments.isEmpty
                else { continue }
                let started = Date()
                guard let notes = await MeetingNotes.generate(
                    transcript: transcript, projects: projects, using: engine
                ) else {
                    print("  \(dir.lastPathComponent): model returned nothing")
                    continue
                }
                notes.write(to: dir, engineName: engine.name)
                let seconds = Int(Date().timeIntervalSince(started))
                print("  \(dir.lastPathComponent) (\(seconds)s): \(notes.title)")
                if let project = notes.project {
                    let meeting = Meeting(
                        dir: dir, hasTranscript: true, isUnread: false, durationSeconds: nil
                    )
                    if let filed = Project.link(
                        meeting: meeting, toProjectNamed: project, root: Config.projectsDir()
                    ) {
                        print("      filed under \(filed)")
                    }
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
