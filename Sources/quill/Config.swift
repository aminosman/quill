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

    /// Persist a new projects root (from the menu's folder picker), keeping
    /// every other key in the config file intact.
    static func setProjectsDir(_ url: URL) {
        var json = load() ?? [:]
        json["projects_dir"] = url.path
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
                "warning: couldn't save projects_dir to \(path.path): \(error)\n".utf8
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
