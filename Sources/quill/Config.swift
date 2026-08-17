import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "auto_record": {
///         "enabled": true,
///         "apps": ["com.tinyspeck.slackmacgap", "us.zoom.xos"],
///         "min_mic_seconds": 3,
///         "stop_grace_seconds": 20
///       },
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    static let defaultProjectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects", isDirectory: true)

    /// Root whose subdirectories are the projects meetings can be linked to.
    static func projectsDir() -> URL {
        guard let dir = load()?["projects_dir"] as? String, !dir.isEmpty else {
            return defaultProjectsRoot
        }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Whether finished transcripts are scanned for project-name mentions
    /// and auto-linked into matching projects' meetings folders. Default on.
    static func autoFileEnabled() -> Bool {
        load()?["auto_file"] as? Bool ?? true
    }

    /// Auto-discard: recordings that are both short and nearly wordless
    /// (accidental triggers, dropped calls) go to the Trash instead of
    /// cluttering the menu. Both thresholds must hold — a long recording is
    /// never discarded no matter how empty its transcript.
    static func autoDiscardEnabled() -> Bool {
        autoDiscard()?["enabled"] as? Bool ?? true
    }

    static func autoDiscardMaxSeconds() -> Int {
        autoDiscard()?["max_seconds"] as? Int ?? 120
    }

    static func autoDiscardMaxWords() -> Int {
        autoDiscard()?["max_words"] as? Int ?? 25
    }

    private static func autoDiscard() -> [String: Any]? {
        load()?["auto_discard"] as? [String: Any]
    }

    /// Persist a new projects root (from the menu's folder picker), keeping
    /// every other key in the config file intact.
    static func setProjectsDir(_ url: URL) {
        set("projects_dir", to: url.path)
    }

    /// Projects enabled for meetings ("meetingable") — only these appear in
    /// link menus and can auto-match. nil = no list saved yet = all projects.
    static func meetingProjects() -> [String]? {
        load()?["meeting_projects"] as? [String]
    }

    static func setMeetingProjects(_ names: [String]) {
        set("meeting_projects", to: names.sorted())
    }

    /// Read-modify-write one key of the config file, preserving the rest.
    private static func set(_ key: String, to value: Any) {
        var json = load() ?? [:]
        json[key] = value
        guard let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: path, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: couldn't save \(key) to \(path.path): \(error)\n".utf8
            ))
        }
    }

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Record a second, independent raw mic track. The voice-processing unit
    /// can silently deliver nothing on some routes; the backup is promoted
    /// over the primary at stop when the primary comes up short, so a stall
    /// costs nothing. nil (default) means "whenever voice processing is on" —
    /// that's the fragile path; set true to always double-capture.
    static func micBackupTrack() -> Bool? {
        load()?["mic_backup_track"] as? Bool
    }

    /// Split the system track into individual speakers (default on). The
    /// system track carries every remote participant, so without this a group
    /// call collapses into one undifferentiated "them".
    static func diarizationEnabled() -> Bool {
        diarization()?["enabled"] as? Bool ?? true
    }

    /// Cosine distance below which a voice is considered the same person as a
    /// known one. Lower = stricter (more new identities, fewer mix-ups).
    static func speakerMatchThreshold() -> Float {
        Float(diarization()?["match_threshold"] as? Double ?? 0.35)
    }

    /// Minimum speech a voice needs before it becomes a person in the
    /// library — below this it's usually crosstalk or a laugh.
    static func speakerMinSeconds() -> Double {
        diarization()?["min_speaker_seconds"] as? Double ?? 15
    }

    /// Infer speaker names from what's said ("I'm Marilyn", "thanks,
    /// Marilyn") and remember them across meetings. Default on.
    static func speakerAutoNameEnabled() -> Bool {
        diarization()?["auto_name"] as? Bool ?? true
    }

    /// Label for your own track. Defaults to "me" — set a real name and it
    /// shows up in transcripts instead.
    static func myName() -> String {
        guard let name = diarization()?["my_name"] as? String, !name.isEmpty else { return "me" }
        return name
    }

    private static func diarization() -> [String: Any]? {
        load()?["diarization"] as? [String: Any]
    }

    /// Drop mic-track segments that duplicate a system-track segment — the
    /// other side's voice coming back through your speakers. Lets raw
    /// capture (reliable) stand in for echo cancellation (fragile).
    static func dedupeBleed() -> Bool {
        load()?["dedupe_bleed"] as? Bool ?? true
    }

    /// Meeting apps and browsers whose mic use auto-starts a recording, as
    /// bundle-ID prefixes — helper processes (com.google.Chrome.helper…)
    /// match their parent. com.apple.WebKit.GPU is where Safari's capture
    /// actually runs.
    static let defaultAutoRecordApps = [
        "com.tinyspeck.slackmacgap",  // Slack
        "us.zoom.xos",  // Zoom
        "com.microsoft.teams2",  // Teams
        "com.microsoft.teams",  // Teams classic
        "com.apple.FaceTime",
        "com.hnc.Discord",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.apple.Safari",
        "com.apple.WebKit.GPU",  // Safari media capture lives here
    ]

    /// Whether another app holding the mic auto-starts a recording. Default
    /// on; also toggleable at runtime from the menu bar.
    static func autoRecordEnabled() -> Bool {
        autoRecord()?["enabled"] as? Bool ?? true
    }

    static func autoRecordApps() -> [String] {
        autoRecord()?["apps"] as? [String] ?? defaultAutoRecordApps
    }

    /// How long a watched app must hold the mic before recording starts —
    /// filters permission prompts, dictation, quick voice searches.
    static func autoRecordMinMicSeconds() -> Double {
        autoRecord()?["min_mic_seconds"] as? Double ?? 3
    }

    /// How long the mic must stay free before an auto-started recording
    /// stops — rides out call drops and rejoins.
    static func autoRecordStopGraceSeconds() -> Double {
        autoRecord()?["stop_grace_seconds"] as? Double ?? 20
    }

    /// Opt-in: seconds of silence on both tracks that mark a meeting
    /// boundary during an auto session — for apps that never release the mic
    /// between calls. Mic release/re-grab detection is the primary boundary
    /// signal; silence guessing stays off unless asked for. 0 disables.
    static func autoRecordSplitSilenceSeconds() -> Double {
        autoRecord()?["split_silence_seconds"] as? Double ?? 0
    }

    private static func autoRecord() -> [String: Any]? {
        load()?["auto_record"] as? [String: Any]
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
