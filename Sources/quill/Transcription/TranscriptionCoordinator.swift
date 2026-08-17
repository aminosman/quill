import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var diarizer: DiarizationEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            // No transcript coming — the recording itself is the deliverable,
            // so it's "ready" (and unread) right now.
            Meeting.markUnread(sessionDir)
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                if discardIfNegligible(dir) { continue }
                Meeting.markUnread(dir)
                notifyTranscriptReady(dir)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        await diarizer?.release()
        diarizer = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }
        if Config.dedupeBleed() {
            let before = merged.count
            merged = Self.withoutBleed(merged)
            if merged.count < before {
                log(dir, "dropped \(before - merged.count) bleed segment(s) from the mic track")
            }
        }

        if Config.diarizationEnabled() {
            merged = await identifySpeakers(in: merged, dir: dir)
        }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    /// Split the system track into individual voices, match each against the
    /// persistent speaker library, then mine the words for names. The mic
    /// track is labeled from config without a model — it's you, always.
    private func identifySpeakers(
        in segments: [Transcript.Segment], dir: URL
    ) async -> [Transcript.Segment] {
        let systemAudio = dir.appendingPathComponent("system.caf")
        guard FileManager.default.fileExists(atPath: systemAudio.path) else { return segments }

        var labeled = segments
        var library = SpeakerLibrary.load()
        let meeting = dir.lastPathComponent

        // Your own track: no diarization needed to know it's you.
        let myName = Config.myName()
        for i in labeled.indices where labeled[i].speaker == "me" {
            labeled[i].speaker_id = "me"
            labeled[i].speaker_name = myName
        }

        do {
            let diarizer = try await preparedDiarizer()
            let turns = try await diarizer.diarize(systemAudio)
            guard !turns.isEmpty else {
                log(dir, "diarization found no speech on the system track")
                return labeled
            }

            // Aggregate per local speaker *before* touching the library: the
            // model already clustered the whole meeting, and one pooled
            // embedding per person is far steadier than dozens of per-turn
            // ones (matching turn-by-turn minted 22 identities for a
            // three-person call — every short interjection looked new).
            let threshold = Config.speakerMatchThreshold()
            var pooled: [String: (embedding: [Float], seconds: Double)] = [:]
            for turn in turns where !turn.embedding.isEmpty {
                if let existing = pooled[turn.localID] {
                    let total = existing.seconds + turn.seconds
                    let weightExisting = Float(existing.seconds / total)
                    let weightNew = Float(turn.seconds / total)
                    pooled[turn.localID] = (
                        zip(existing.embedding, turn.embedding).map {
                            $0 * weightExisting + $1 * weightNew
                        },
                        total
                    )
                } else {
                    pooled[turn.localID] = (turn.embedding, turn.seconds)
                }
            }

            // A voice with only a moment of speech is usually a crosstalk
            // artifact; label its turns but never let it create a person.
            let minSeconds = Config.speakerMinSeconds()
            var localToLibrary: [String: String] = [:]
            for (localID, voice) in pooled.sorted(by: { $0.value.seconds > $1.value.seconds }) {
                guard voice.seconds >= minSeconds else { continue }
                localToLibrary[localID] = library.resolve(
                    embedding: voice.embedding,
                    seconds: voice.seconds,
                    meeting: meeting,
                    threshold: threshold
                )
            }
            // Fold the fragments into whichever real voice they sound like.
            for (localID, voice) in pooled where localToLibrary[localID] == nil {
                let nearest = localToLibrary
                    .compactMap { entry -> (String, Float)? in
                        guard let centroid = library.voice(for: entry.value)?.centroid
                        else { return nil }
                        return (
                            entry.value,
                            SpeakerLibrary.cosineDistance(voice.embedding, centroid)
                        )
                    }
                    .min { $0.1 < $1.1 }
                if let nearest, nearest.1 <= threshold * 1.5 {
                    localToLibrary[localID] = nearest.0
                }
            }

            let resolved: [(turn: DiarizationEngine.Turn, id: String)] = turns.compactMap { turn in
                localToLibrary[turn.localID].map { (turn, $0) }
            }

            // Attribute each transcript segment to the voice it overlaps most.
            for i in labeled.indices where labeled[i].speaker == "them" {
                let start = TimeInterval(labeled[i].start_ms) / 1000
                let end = TimeInterval(labeled[i].end_ms) / 1000
                var bestID: String?
                var bestOverlap: TimeInterval = 0
                for entry in resolved {
                    let overlap = min(end, entry.turn.end) - max(start, entry.turn.start)
                    if overlap > bestOverlap {
                        bestOverlap = overlap
                        bestID = entry.id
                    }
                }
                labeled[i].speaker_id = bestID
                labeled[i].speaker_name = bestID.flatMap { library.name(for: $0) }
            }

            // Speaker playback lands on the mic track too, so the mic can be
            // mostly *other people* — worst case you were muted and every
            // word on it is bleed. Text matching only catches the lines both
            // engines transcribed alike; voice identity catches all of it, so
            // diarize the mic track and drop whatever sounds like a remote
            // speaker rather than like you.
            labeled = await dropBleedByVoice(
                in: labeled,
                dir: dir,
                remoteVoices: localToLibrary.values.compactMap { library.voice(for: $0) },
                threshold: threshold
            )

            // Name mining: evidence accumulates in the library, so a name
            // spoken in any past meeting can settle today's unnamed voice.
            if Config.speakerAutoNameEnabled() {
                let evidence = NameDetective.evidence(from: labeled)
                library.addNameEvidence(evidence, autoName: true)
                for i in labeled.indices {
                    if let id = labeled[i].speaker_id, id != "me" {
                        labeled[i].speaker_name = library.name(for: id)
                    }
                }
            }
            library.save()

            let voices = Set(labeled.compactMap(\.speaker_id)).subtracting(["me"])
            let named = voices.compactMap { library.name(for: $0) }
            log(
                dir,
                "diarization: \(voices.count) remote voice(s)"
                    + (named.isEmpty ? "" : ", identified \(named.joined(separator: ", "))")
            )
        } catch {
            log(dir, "diarization skipped: \(error)")
        }
        return labeled
    }

    /// Re-run diarization and name inference over an already-transcribed
    /// session, rewriting its transcript. Used by `quill speakers
    /// --backfill` to seed the voice library from history.
    func redoSpeakers(in dir: URL) async {
        guard var transcript = Transcript.read(from: dir) else { return }
        transcript.segments = await identifySpeakers(in: transcript.segments, dir: dir)
        try? transcript.write(to: dir)
        // Deliberately keeps the diarizer loaded: releasing per session made
        // a backfill recompile the Core ML models on every recording, which
        // dominated the run. Call releaseEngines() when the sweep is done.
    }

    /// Drop loaded models — for one-shot CLI work that's finished with them.
    func releaseEngines() async {
        await engine?.release()
        engine = nil
        await diarizer?.release()
        diarizer = nil
    }

    /// Remove mic-track segments whose audio belongs to a remote participant.
    /// Each mic voice is compared against this meeting's remote voices: the
    /// ones that match are echo, the leftovers are you. Cheap and decisive
    /// where text comparison is neither — it needs no agreement between two
    /// independent transcriptions of the same words.
    private func dropBleedByVoice(
        in segments: [Transcript.Segment],
        dir: URL,
        remoteVoices: [SpeakerLibrary.Voice],
        threshold: Float
    ) async -> [Transcript.Segment] {
        guard Config.dedupeBleed(), !remoteVoices.isEmpty else { return segments }
        let micAudio = dir.appendingPathComponent("mic.caf")
        guard FileManager.default.fileExists(atPath: micAudio.path) else { return segments }

        let turns: [DiarizationEngine.Turn]
        do {
            turns = try await preparedDiarizer().diarize(micAudio)
        } catch {
            log(dir, "mic diarization skipped: \(error)")
            return segments
        }
        guard !turns.isEmpty else { return segments }

        // Pool per mic voice, then ask each one: do you sound like someone on
        // the far end?
        var pooled: [String: (embedding: [Float], seconds: Double)] = [:]
        for turn in turns where !turn.embedding.isEmpty {
            if let existing = pooled[turn.localID] {
                let total = existing.seconds + turn.seconds
                let weightExisting = Float(existing.seconds / total)
                let weightNew = Float(turn.seconds / total)
                pooled[turn.localID] = (
                    zip(existing.embedding, turn.embedding).map {
                        $0 * weightExisting + $1 * weightNew
                    },
                    total
                )
            } else {
                pooled[turn.localID] = (turn.embedding, turn.seconds)
            }
        }

        var echoVoices: Set<String> = []
        for (localID, voice) in pooled {
            let nearest = remoteVoices
                .map { SpeakerLibrary.cosineDistance(voice.embedding, $0.centroid) }
                .min() ?? .greatestFiniteMagnitude
            if nearest <= threshold { echoVoices.insert(localID) }
        }
        guard !echoVoices.isEmpty else { return segments }

        let echoTurns = turns.filter { echoVoices.contains($0.localID) }
        let mineTurns = turns.filter { !echoVoices.contains($0.localID) }
        let micOffset = TimeInterval(SessionMeta.micOffsetMs(in: dir)) / 1000

        var kept: [Transcript.Segment] = []
        var dropped = 0
        for segment in segments {
            guard segment.speaker == "me" else { kept.append(segment); continue }
            // Diarization timestamps are raw track time; transcript timestamps
            // carry the track's start offset.
            let start = TimeInterval(segment.start_ms) / 1000 - micOffset
            let end = TimeInterval(segment.end_ms) / 1000 - micOffset
            let echo = Self.overlap(start, end, echoTurns)
            let mine = Self.overlap(start, end, mineTurns)
            // Keep anything you plausibly said: only drop when the echo voice
            // clearly dominates the segment.
            if echo > mine, echo >= (end - start) * 0.5 {
                dropped += 1
            } else {
                kept.append(segment)
            }
        }
        if dropped > 0 {
            log(
                dir,
                "dropped \(dropped) mic segment(s) matching a remote voice"
                    + " (\(echoVoices.count) of \(pooled.count) mic voice(s) were echo)"
            )
        }
        return kept
    }

    private static func overlap(
        _ start: TimeInterval, _ end: TimeInterval, _ turns: [DiarizationEngine.Turn]
    ) -> TimeInterval {
        turns.reduce(0) { total, turn in
            total + max(0, min(end, turn.end) - max(start, turn.start))
        }
    }

    private func preparedDiarizer() async throws -> DiarizationEngine {
        if let diarizer { return diarizer }
        let diarizer = DiarizationEngine()
        try await diarizer.prepare()
        self.diarizer = diarizer
        return diarizer
    }

    /// Speaker playback reaches the mic, so the other side's words land on
    /// both tracks. The system track is the true source for their voice, so
    /// drop the mic copy: any "me" segment whose text repeats a nearby
    /// "them" segment. Conservative on purpose — needs a real textual
    /// overlap (short utterances like "yeah" are left alone, since both
    /// people genuinely say them).
    fileprivate static func withoutBleed(
        _ segments: [Transcript.Segment]
    ) -> [Transcript.Segment] {
        let them = segments.filter { $0.speaker == "them" }
        guard !them.isEmpty else { return segments }
        let window = 6000

        // Pre-tokenize once: this is O(me × them) and meetings run to
        // thousands of segments.
        let theirTokens = them.map { (seg: $0, tokens: tokenSet($0.text)) }

        return segments.filter { seg in
            guard seg.speaker == "me" else { return true }
            let mine = tokenSet(seg.text)
            // Needs enough words to be distinctive; "yeah" and "okay" are
            // said independently by everyone.
            guard mine.count >= 3 else { return true }
            return !theirTokens.contains { other in
                // Direction matters: playback reaches the mic *after* it
                // reaches the file (measured ≥96ms on real sessions), so a
                // bleed copy always starts later than its source. When the
                // mic segment came first it's genuinely you — coincidental
                // phrase overlap must never delete your own words.
                guard other.seg.start_ms < seg.start_ms,
                      seg.start_ms - other.seg.start_ms <= window,
                      other.tokens.count >= 3
                else { return false }
                // Word-overlap, not containment: the two tracks are
                // transcribed independently, so the same sentence comes back
                // slightly different ("they've done work" vs "there's done
                // work") and exact matching misses most real bleed.
                let shared = mine.intersection(other.tokens).count
                let smaller = min(mine.count, other.tokens.count)
                return Double(shared) / Double(smaller) >= 0.7
            }
        }
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(normalizeText(text).split(separator: " ").map(String.init))
    }

    private static func normalizeText(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Three distinct notifications so the menu doesn't need opening to know
    /// what happened: filed (which projects), ambiguous (mentioned but only
    /// in passing — user should file it), or plain ready (no project came up).
    private func notifyTranscriptReady(_ dir: URL) {
        let name = dir.lastPathComponent
        guard Config.autoFileEnabled() else {
            notifyUser(title: "quill — transcript ready", body: name)
            return
        }
        let result = Project.autoFile(dir, projectsRoot: Config.projectsDir())
        if let filed = result.filed {
            // Categorized — nothing left to do, so the unread dot clears.
            Meeting(dir: dir, hasTranscript: true, isUnread: false, durationSeconds: nil)
                .markRead()
            notifyUser(
                title: "quill — transcript filed",
                body: "\(name) → \(filed)"
            )
        } else if !result.ambiguous.isEmpty {
            notifyUser(
                title: "quill — transcript needs filing",
                body: "\(name) mentions \(result.ambiguous.joined(separator: ", ")) "
                    + "only in passing — file it from the menu."
            )
        } else {
            notifyUser(
                title: "quill — transcript ready",
                body: "\(name) — no project detected; file it from the menu."
            )
        }
    }

    /// A recording both shorter than max_seconds and emptier than max_words
    /// is noise — an accidental trigger, a dropped call. Move it to the
    /// Trash (recoverable) and skip the unread/auto-file/hook pipeline.
    private func discardIfNegligible(_ dir: URL) -> Bool {
        guard Config.autoDiscardEnabled() else { return false }
        guard
            let meta = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
            let metaJson = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
            let duration = metaJson["duration_seconds"] as? Int,
            duration <= Config.autoDiscardMaxSeconds()
        else { return false }
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let segments = json["segments"] as? [[String: Any]]
        else { return false }
        let words = segments
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .count
        guard words <= Config.autoDiscardMaxWords() else { return false }

        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            log(dir, "auto-discard failed: \(error)")
            return false
        }
        FileHandle.standardError.write(Data(
            "discarded \(dir.lastPathComponent) (\(duration)s, \(words) words) → Trash\n".utf8
        ))
        notifyUser(
            title: "quill — short recording discarded",
            body: "\(dir.lastPathComponent) (\(duration)s, \(words) words) moved to Trash."
        )
        return true
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    /// Offset already baked into the mic track's transcript timestamps, so
    /// they can be converted back to raw track time for comparison with
    /// diarization output.
    static func micOffsetMs(in dir: URL) -> Int {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let offsets = json["start_offset_ms"] as? [String: Int]
        else { return 0 }
        return offsets["mic"] ?? 0
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}
