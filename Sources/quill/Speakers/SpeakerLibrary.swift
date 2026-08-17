import Foundation

/// Local, persistent voice identities at ~/.config/quill/speakers.json.
///
/// Diarization gives each meeting its own arbitrary speaker numbering, which
/// is useless across meetings. The library turns those into durable people:
/// every voice carries a centroid embedding, and a new meeting's voices are
/// matched against it by cosine distance. Once a voice has a name — typed in
/// the viewer, or inferred from someone saying it out loud (see
/// [NameDetective]) — every future meeting with that voice is labeled
/// automatically, and past transcripts can be relabeled.
///
/// Nothing leaves the machine: embeddings are 256 floats of voice timbre,
/// stored beside the config.
struct SpeakerLibrary: Codable {
    struct Voice: Codable {
        let id: String
        /// Confirmed name, shown everywhere once set.
        var name: String?
        /// Running centroid of this voice's embeddings, duration-weighted.
        var centroid: [Float]
        /// Total speech seconds attributed to this voice, all meetings.
        var totalSeconds: Double
        /// Accumulated name evidence: candidate → score, summed across
        /// meetings. This is what lets a name heard last week resolve a
        /// silent introduction this week.
        var nameEvidence: [String: Double]
        var meetings: [String]
        var firstSeen: Date
        var lastSeen: Date

        /// Best guess, shown as "Alex?" for one-click confirmation: a clear
        /// winner at twice the runner-up. Same single-winner discipline as
        /// project auto-filing — a coin flip is worse than no guess.
        var suggestedName: String? {
            let ranked = nameEvidence.sorted { $0.value > $1.value }
            guard let top = ranked.first, top.value >= 2.0 else { return nil }
            if let second = ranked.dropFirst().first, top.value < second.value * 2 {
                return nil
            }
            return top.key
        }

        /// Applied without asking. Two ways to qualify: corroborated
        /// evidence (a self-introduction plus a later mention, or several
        /// addresses), or a single candidate with nobody competing for this
        /// voice — one clear "how's your weekend, Caitlin?" and no rival name
        /// is worth acting on, where the same score split against another
        /// candidate is not. A wrong name is worse than an unnamed voice, but
        /// so is never naming anyone.
        var confidentName: String? {
            guard let suggested = suggestedName else { return nil }
            let score = nameEvidence[suggested] ?? 0
            if score >= 4.0 { return suggested }
            return nameEvidence.count == 1 && score >= 2.0 ? suggested : nil
        }
    }

    var voices: [Voice] = []

    // MARK: - Persistence

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/speakers.json")

    static func load() -> SpeakerLibrary {
        guard let data = try? Data(contentsOf: path) else { return SpeakerLibrary() }
        let decoder = JSONDecoder()
        // Must mirror save()'s .iso8601: with the default strategy every load
        // failed to decode and silently returned an empty library, so voices
        // never matched across meetings and name evidence never accumulated.
        decoder.dateDecodingStrategy = .iso8601
        guard let library = try? decoder.decode(SpeakerLibrary.self, from: data) else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is unreadable — starting a fresh speaker library\n".utf8
            ))
            return SpeakerLibrary()
        }
        return library
    }

    /// Merge with the on-disk library before writing. The daemon and the CLI
    /// both read-modify-write this file, and a stale snapshot overwriting a
    /// fresh one lost whole backfills.
    func save() {
        var merged = Self.load()
        for voice in voices {
            if let index = merged.voices.firstIndex(where: { $0.id == voice.id }) {
                // Ours is the newer observation of this voice.
                merged.voices[index] = voice
            } else {
                merged.voices.append(voice)
            }
        }
        merged.writeToDisk()
    }

    private func writeToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.path, options: .atomic)
    }

    // MARK: - Lookup

    func name(for id: String) -> String? {
        voices.first { $0.id == id }?.name
    }

    func voice(for id: String) -> Voice? {
        voices.first { $0.id == id }
    }

    /// "Speaker 3b1f" — stable, recognizable, and obviously not a real name.
    static func shortLabel(for id: String) -> String {
        "Speaker \(id.prefix(4))"
    }

    mutating func rename(id: String, to name: String?) {
        guard let index = voices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        voices[index].name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // A typed name is ground truth: make it outrank accumulated guesses
        // so a later inference can't quietly override it.
        if let confirmed = voices[index].name {
            voices[index].nameEvidence[confirmed] =
                (voices[index].nameEvidence[confirmed] ?? 0) + 100
        }
    }

    /// Match `embedding` to a known voice or mint a new one, folding the new
    /// sample into the centroid. Returns the voice id.
    mutating func resolve(
        embedding: [Float],
        seconds: Double,
        meeting: String,
        threshold: Float
    ) -> String {
        guard !embedding.isEmpty else { return "" }

        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, voice) in voices.enumerated() {
            let distance = Self.cosineDistance(embedding, voice.centroid)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        if let index = bestIndex, bestDistance <= threshold {
            // Duration-weighted centroid update: a 40-minute voice shouldn't
            // be dragged around by a 2-second interjection.
            let voice = voices[index]
            let weight = Float(max(seconds, 0.5))
            let existing = Float(max(voice.totalSeconds, 0.5))
            voices[index].centroid = zip(voice.centroid, embedding).map {
                ($0 * existing + $1 * weight) / (existing + weight)
            }
            voices[index].totalSeconds += seconds
            voices[index].lastSeen = Date()
            if !voices[index].meetings.contains(meeting) {
                voices[index].meetings.append(meeting)
            }
            return voice.id
        }

        let voice = Voice(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            name: nil,
            centroid: embedding,
            totalSeconds: seconds,
            nameEvidence: [:],
            meetings: [meeting],
            firstSeen: Date(),
            lastSeen: Date()
        )
        voices.append(voice)
        return voice.id
    }

    /// Fold in name evidence gathered from a transcript, promoting a
    /// suggestion to a confirmed name when it's strong and unambiguous.
    mutating func addNameEvidence(_ evidence: [String: [String: Double]], autoName: Bool) {
        for (voiceID, candidates) in evidence {
            guard let index = voices.firstIndex(where: { $0.id == voiceID }) else { continue }
            for (name, score) in candidates {
                voices[index].nameEvidence[name] =
                    (voices[index].nameEvidence[name] ?? 0) + score
            }
            if autoName, voices[index].name == nil,
               let confident = voices[index].confidentName {
                voices[index].name = confident
            }
        }
    }

    /// 1 - cosine similarity; 0 is identical, 1 is orthogonal.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return .greatestFiniteMagnitude }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }
}
