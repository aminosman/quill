import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, Speakers.self, Notes.self, Models.self],
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

        requestNotificationAuthorization()
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
    /// App Nap defers a windowless agent's timers by minutes — long enough
    /// to sleep through an entire between-meetings gap (observed: a 20s stop
    /// grace that fired only when the next meeting grabbed the mic). Watching
    /// the mic is this process's whole job; keep it awake.
    private let napExemption = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "meeting detection timers"
    )
    private var session: RecordingSession?
    private var ticker: Timer?
    private var autoRecord = Config.autoRecordEnabled()
    /// True while the live session was started by the mic monitor rather than
    /// a click — only those sessions auto-stop when the mic frees up.
    private var sessionAutoStarted = false
    /// Set once an auto session has been silent (both tracks) longer than the
    /// split threshold; the next sound is then a meeting boundary.
    private var splitArmed = false
    /// One mic restart per session — a dead device shouldn't restart forever.
    private var micRestarted = false

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
        splitArmed = false
        micRestarted = false
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
        // .common modes, not scheduledTimer: menu tracking parks the run loop
        // in NSEventTrackingRunLoopMode, where default-mode timers stall —
        // the elapsed counter must keep ticking while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
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
        checkSilenceSplit(session)
        checkMicStall(session)
    }

    /// The 2.5s startup watchdog can't catch a tap that dies at minute 40.
    /// If the mic has delivered nothing for 10s while recording, restart it
    /// raw — once per session, so a genuinely broken device doesn't loop.
    private func checkMicStall(_ session: RecordingSession) {
        guard !micRestarted, let idle = session.secondsSinceMicFrame, idle >= 10 else { return }
        micRestarted = true
        session.restartMicRaw(reason: "no audio for \(Int(idle))s")
        notifyUser(
            title: "quill — mic capture restarted",
            body: "The microphone stopped delivering audio; recording continues."
        )
    }

    /// Back-to-back meetings often share one mic grab — the app never
    /// releases it between calls, so the idle detector can't see the
    /// boundary. Audio can: both tracks quiet past the threshold arms a
    /// split, and the next sound rotates to a fresh session. Splitting on
    /// resume (not mid-gap) keeps the silent tail in the old meeting and
    /// creates nothing when no next meeting comes.
    private func checkSilenceSplit(_ session: RecordingSession) {
        guard sessionAutoStarted else { return }
        let threshold = Config.autoRecordSplitSilenceSeconds()
        guard threshold > 0 else { return }
        if Date().timeIntervalSince(session.lastActivityAt) >= threshold {
            splitArmed = true
        } else if splitArmed {
            splitArmed = false
            FileHandle.standardError.write(Data(
                "✂ sound after a \(Int(threshold))s+ gap — rotating to a new session\n".utf8
            ))
            stopSession()
            startSession()
            guard self.session != nil else { return }
            sessionAutoStarted = true
            notifyUser(
                title: "quill — new meeting detected",
                body: "Recording split — the previous meeting is transcribing."
            )
        }
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
