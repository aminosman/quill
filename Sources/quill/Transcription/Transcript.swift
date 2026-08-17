import Foundation

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
///
/// `side` is the track a segment came from (`me` = mic, `them` = system) and
/// is always exact. `speaker_id` / `speaker_name` come from diarization: the
/// system track carries every remote participant, so it gets split into
/// individual voices, each resolved against the local speaker library. The
/// mic track needs no model — it's one person by construction.
struct Transcript: Codable {
    struct Segment: Codable {
        /// Retained under its original name so existing tooling keeps working;
        /// values stay "me"/"them".
        let speaker: String
        var speaker_id: String?
        var speaker_name: String?
        let start_ms: Int
        let end_ms: Int
        let text: String

        /// Display label: a real name when known, else the voice's short id.
        var label: String {
            if let speaker_name, !speaker_name.isEmpty { return speaker_name }
            if speaker == "me" { return "me" }
            return speaker_id.map { SpeakerLibrary.shortLabel(for: $0) } ?? "them"
        }
    }

    let engine: String
    let model: String
    let created_at: String
    var segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    static func read(from dir: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Re-apply names from the speaker library and rewrite both files — what
    /// renaming a voice in the viewer calls, so a name given today
    /// materializes in transcripts recorded before it was known.
    static func relabel(dir: URL, using library: SpeakerLibrary) {
        guard var transcript = read(from: dir) else { return }
        for i in transcript.segments.indices {
            guard let id = transcript.segments[i].speaker_id else { continue }
            transcript.segments[i].speaker_name = library.name(for: id)
        }
        try? transcript.write(to: dir)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))"]
        let voices = Set(segments.compactMap(\.speaker_id))
        if !voices.isEmpty {
            let names = Set(segments.map(\.label)).sorted().joined(separator: ", ")
            lines.append("speakers: \(names)")
        }
        lines.append("")
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.label):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
