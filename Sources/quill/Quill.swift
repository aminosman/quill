import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar: MenuBarController
    private let transcription = TranscriptionCoordinator()
    private let micMonitor: MicActivityMonitor
    private var session: RecordingSession?
    private var ticker: Timer?
    private var autoRecord = Config.autoRecordEnabled()
    /// True while the live session was started by the mic monitor rather than
    /// a click — only those sessions auto-stop when the mic frees up.
    private var sessionAutoStarted = false

    init(root: URL) {
        self.root = root
        menuBar = MenuBarController(recordingsRoot: root, projectsRoot: Config.projectsDir())
        micMonitor = MicActivityMonitor(
            watchlist: Config.autoRecordApps(),
            startDelay: Config.autoRecordMinMicSeconds(),
            stopGrace: Config.autoRecordStopGraceSeconds()
        )
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onToggleAutoRecord = { [weak self] in self?.toggleAutoRecord() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)
        menuBar.setAutoRecord(autoRecord)

        micMonitor.onMicActive = { [weak self] bundleID in self?.autoStart(trigger: bundleID) }
        micMonitor.onMicIdle = { [weak self] in self?.autoStop() }
        micMonitor.start()

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        // A manual click always takes ownership: a manually stopped session
        // won't auto-restart until the mic goes fully idle and comes back.
        sessionAutoStarted = false
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func toggleAutoRecord() {
        autoRecord.toggle()
        menuBar.setAutoRecord(autoRecord)
    }

    private func autoStart(trigger bundleID: String) {
        guard autoRecord, session == nil else { return }
        startSession()
        guard session != nil else { return }
        sessionAutoStarted = true
        notifyUser(
            title: "quill — recording started",
            body: "\(Self.appName(for: bundleID)) is using the microphone. "
                + "Stops when the mic frees up, or from the menu bar."
        )
    }

    private func autoStop() {
        guard sessionAutoStarted else { return }
        sessionAutoStarted = false
        stopSession()
        notifyUser(
            title: "quill — recording stopped",
            body: "The microphone is no longer in use."
        )
    }

    /// Human name for a bundle ID, walking up parent bundles so helper
    /// processes (com.google.Chrome.helper) resolve to the app they belong to.
    private static func appName(for bundleID: String) -> String {
        var candidate = bundleID
        while !candidate.isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                return url.deletingPathExtension().lastPathComponent
            }
            candidate = candidate.split(separator: ".").dropLast().joined(separator: ".")
        }
        return bundleID
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription, weak self] in
            await transcription.enqueue(dir)
            // With transcription disabled, the session went straight to
            // "ready" inside enqueue — reflect the unread dot now.
            self?.menuBar.refreshUnread()
        }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        // Every status change is a moment a transcript may have just landed.
        menuBar.refreshUnread()
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
