import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Most recent moment either track carried real signal — voice-level on
    /// the mic, any audio on the system track. `startedAt` until first sound.
    var lastActivityAt: Date {
        max(mic.activity.value ?? startedAt, system.activity.value ?? startedAt)
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
    }

    /// Seconds since the mic tap last delivered audio (nil before the first
    /// buffer) — the stall watchdog's input.
    var secondsSinceMicFrame: TimeInterval? { mic.secondsSincePrimaryFrame }

    /// Restart mic capture raw mid-session, keeping the same file.
    func restartMicRaw(reason: String) { mic.restartRaw(reason: reason) }

    /// Stop both tracks and write meta.json.
    func stop() {
        mic.stop()
        system.stop()

        // Failover: if the primary mic track came up empty (or far short of
        // the backup) promote the backup over it, so transcription and every
        // downstream consumer just find a healthy mic.caf.
        let micURL = dir.appendingPathComponent("mic.caf")
        var micRecovered = false
        if let backupURL = mic.backupURL, mic.backupFrameCount > mic.primaryFrameCount * 2 {
            do {
                _ = try FileManager.default.replaceItemAt(micURL, withItemAt: backupURL)
                micRecovered = true
                FileHandle.standardError.write(Data(
                    "mic: primary track was short (\(mic.primaryFrameCount) frames) — promoted backup (\(mic.backupFrameCount) frames)\n"
                        .utf8
                ))
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: promoting mic backup failed: \(error)\n".utf8
                ))
            }
        } else if let backupURL = mic.backupURL {
            try? FileManager.default.removeItem(at: backupURL)
        }

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // Integrity: a track that captured far less audio than the session
        // lasted is a silent failure — surface it instead of shipping a
        // half-empty transcript that reads as "they did all the talking".
        let expected = ended.timeIntervalSince(startedAt)
        let micSeconds = Double(mic.primaryFrameCount) / 48000
        let micOK = micRecovered || expected < 5 || micSeconds >= expected * 0.5
        if !micOK {
            FileHandle.standardError.write(Data(
                "warning: mic track only \(Int(micSeconds))s of \(Int(expected))s — your side may be missing\n"
                    .utf8
            ))
            notifyUser(
                title: "quill — mic track incomplete",
                body: "\(dir.lastPathComponent): captured \(Int(micSeconds))s of \(Int(expected))s. "
                    + "Your side of this meeting may be missing."
            )
        }

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        let meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
            // Recorded so a thin transcript can always be explained after
            // the fact, without re-deriving it from file sizes.
            "tracks": [
                "mic_seconds_captured": Int(micSeconds),
                "mic_complete": micOK,
                "mic_recovered_from_backup": micRecovered,
            ],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
