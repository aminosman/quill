import Foundation

/// Infers speaker names from the words in a meeting, so voices become people
/// without anyone typing anything.
///
/// Three signals, weighted by how much they actually prove:
///   * **Self-introduction** ("I'm Marilyn", "this is Marilyn") inside a
///     voice's own turn — the strongest evidence there is.
///   * **Answered address** ("Marilyn, what do you think?") — the *next*
///     different voice to speak is probably Marilyn.
///   * **Thanks/acknowledgement** ("Thanks, Marilyn") — the voice that just
///     finished speaking is probably Marilyn.
///
/// Evidence is deliberately weak per mention and accumulates in the speaker
/// library across meetings: a name said once last week plus once today
/// clears the bar that neither would alone. Nothing is auto-applied unless
/// one candidate is twice its runner-up, so an ambiguous room stays unnamed
/// rather than mislabeled.
enum NameDetective {
    /// voiceID → (candidate name → score)
    static func evidence(from segments: [Transcript.Segment]) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        func add(_ voiceID: String?, _ name: String, _ weight: Double) {
            guard let voiceID, !voiceID.isEmpty else { return }
            out[voiceID, default: [:]][name, default: 0] += weight
        }

        for (index, segment) in segments.enumerated() {
            let text = segment.text

            for name in selfIntroductions(in: text) {
                add(segment.speaker_id, name, 3.0)
            }

            // Vocatives point at *another* voice, so they need the
            // neighbouring turns rather than this one.
            for (name, kind) in addresses(in: text) where !isQuoted(name, in: text) {
                switch kind {
                case .question:
                    if let next = nextDifferentVoice(from: index, in: segments) {
                        add(next, name, 2.0)
                    }
                case .acknowledgement:
                    if let previous = previousDifferentVoice(from: index, in: segments) {
                        add(previous, name, 1.5)
                    }
                case .greeting:
                    // "Hi Marilyn" — she typically answers next, but a
                    // round of hellos is noisy, so weight it lightly.
                    if let next = nextDifferentVoice(from: index, in: segments) {
                        add(next, name, 0.75)
                    }
                }
            }
        }
        return out
    }

    // MARK: - Patterns

    private enum AddressKind { case question, acknowledgement, greeting }

    /// "I'm Marilyn", "my name is Marilyn", "this is Marilyn (speaking)",
    /// "Marilyn here".
    private static func selfIntroductions(in text: String) -> [String] {
        var names: [String] = []
        let patterns = [
            #"\bI['’]m\s+([A-Z][a-z]{2,15})\b"#,
            #"\bI am\s+([A-Z][a-z]{2,15})\b"#,
            #"\bmy name['’]?s?\s+(?:is\s+)?([A-Z][a-z]{2,15})\b"#,
            #"\bthis is\s+([A-Z][a-z]{2,15})\b"#,
        ]
        for pattern in patterns {
            names += captures(of: pattern, in: text)
        }
        // "NAME here" has no lexical anchor, so a sentence-initial word can
        // masquerade as a name — that's how "Murderer here is…" once
        // nominated "Murderer" as a participant. Every other pattern carries
        // its own trigger words ("I'm", "thanks,", a trailing "?"), so the
        // capital letter isn't doing the work alone and a leading vocative
        // like "Caitlin, what do you think?" stays eligible.
        names += captures(of: #"\b([A-Z][a-z]{2,15})\s+here\b"#, in: text)
            .filter { appearsMidSentence($0, in: text) }
        return names.filter(isPlausibleName)
    }

    /// Vocatives: a name set off by punctuation or leading a question.
    private static func addresses(in text: String) -> [(String, AddressKind)] {
        var found: [(String, AddressKind)] = []

        for name in captures(of: #"\b(?:thanks|thank you|appreciate it|got it|agreed)[,\s]+([A-Z][a-z]{2,15})\b"#, in: text, caseInsensitive: true)
        where isPlausibleName(name) {
            found.append((name, .acknowledgement))
        }
        for name in captures(of: #"\b(?:hi|hey|hello|welcome)[,\s]+([A-Z][a-z]{2,15})\b"#, in: text, caseInsensitive: true)
        where isPlausibleName(name) {
            found.append((name, .greeting))
        }
        // "Marilyn, what do you think?" / "Marilyn, could you…"
        for name in captures(of: #"\b([A-Z][a-z]{2,15}),\s+(?:what|how|why|when|where|do|does|did|can|could|would|will|are|is|any)\b"#, in: text)
        where isPlausibleName(name) {
            found.append((name, .question))
        }
        // Trailing vocative closing a question: "how's your weekend,
        // Caitlin?" — whoever answers next is Caitlin. This is the most
        // common way people actually address each other on a call.
        for name in captures(of: #"\b[a-z]{2,}[,\s]+([A-Z][a-z]{2,15})\s*\?"#, in: text)
        where isPlausibleName(name) {
            found.append((name, .question))
        }
        // Trailing vocative closing a statement: "that makes sense, Caitlin."
        for name in captures(of: #"\b[a-z]{2,},\s+([A-Z][a-z]{2,15})\s*[.!]"#, in: text)
        where isPlausibleName(name) {
            found.append((name, .acknowledgement))
        }
        // "over to you, Marilyn" / "back to you, Marilyn"
        for name in captures(of: #"\b(?:over to you|back to you|to you)[,\s]+([A-Z][a-z]{2,15})\b"#, in: text, caseInsensitive: true)
        where isPlausibleName(name) {
            found.append((name, .question))
        }
        return found
    }

    /// True when every occurrence of the name is introduced by a quotative —
    /// "I was like, Caitlin, …", "they say, Caitlin, …". People roleplay
    /// conversations constantly on sales calls, and those lines address
    /// nobody in the room.
    private static func isQuoted(_ name: String, in text: String) -> Bool {
        let quotatives = ["like,", "like", "saying,", "saying", "say,", "say", "said,", "said"]
        var search = text.startIndex..<text.endIndex
        var sawUnquoted = false
        var sawAny = false
        while let found = text.range(of: name, range: search) {
            sawAny = true
            let prefix = text[text.startIndex..<found.lowerBound]
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .suffix(2)
                .map { $0.lowercased() }
            if !prefix.contains(where: { quotatives.contains($0) }) { sawUnquoted = true }
            search = found.upperBound..<text.endIndex
        }
        return sawAny && !sawUnquoted
    }

    /// ASR capitalizes the first word of every sentence, so a sentence-initial
    /// match proves nothing — that's how "Murderer here is…" once nominated
    /// "Murderer" as a participant. Require at least one mid-sentence
    /// occurrence, where capitalization is real evidence of a proper noun.
    private static func appearsMidSentence(_ name: String, in text: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let found = text.range(of: name, range: search) {
            var index = found.lowerBound
            var sentenceInitial = true
            while index > text.startIndex {
                index = text.index(before: index)
                let character = text[index]
                if character.isWhitespace { continue }
                sentenceInitial = ".!?".contains(character)
                break
            }
            if !sentenceInitial { return true }
            search = found.upperBound..<text.endIndex
        }
        return false
    }

    private static func captures(
        of pattern: String, in text: String, caseInsensitive: Bool = false
    ) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[captured])
        }
    }

    /// ASR output is capitalized prose, so a capitalized token is a weak
    /// proper-noun signal — filter the words that merely start sentences or
    /// name places, companies, and days.
    private static func isPlausibleName(_ candidate: String) -> Bool {
        let name = candidate.trimmingCharacters(in: .punctuationCharacters)
        guard name.count >= 3, name.count <= 15,
              name.allSatisfy(\.isLetter),
              let first = name.first, first.isUppercase
        else { return false }
        return !blocklist.contains(name.lowercased())
    }

    /// Words that show up capitalized mid-sentence but are never the person
    /// being addressed. Cheaper and more predictable than a name gazetteer,
    /// and a false candidate needs to beat the real one 2:1 to matter.
    private static let blocklist: Set<String> = [
        // discourse / sentence starters
        "yeah", "yes", "okay", "sure", "right", "well", "sorry", "thanks", "thank",
        "hello", "hey", "good", "great", "nice", "perfect", "exactly", "actually",
        "maybe", "sort", "kind", "just", "like", "really", "very", "much", "also",
        "and", "but", "the", "this", "that", "these", "those", "there", "here",
        "what", "when", "where", "why", "how", "who", "which", "our", "your",
        "their", "his", "her", "its", "were", "was", "will", "would", "could",
        "should", "have", "has", "had", "did", "does", "done", "going", "gonna",
        // frequent capitalized non-people
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "june", "july",
        "august", "september", "october", "november", "december",
        "google", "slack", "zoom", "teams", "claude", "chatgpt", "openai",
        "america", "american", "california", "york", "jersey", "francisco",
        "london", "canada", "europe", "africa", "asia", "walmart", "amazon",
        "english", "spanish", "french", "german", "chinese",
        "god", "jesus", "christmas", "internet", "excel", "sheets", "figma",
        // observed false candidates from real transcripts
        "likewise", "talent", "everyone", "everybody", "guys", "folks", "team",
        "all", "both", "again", "still", "back", "next", "last", "first",
    ]

    // MARK: - Neighbouring turns

    /// Address-based evidence only makes sense within a conversational beat —
    /// beyond ~30s the reply is a different exchange.
    private static let neighbourWindowMs = 30_000

    /// "Yeah." / "Okay." answer nothing — the real reply is the next turn
    /// with actual content.
    private static func isSubstantial(_ text: String) -> Bool {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count >= 4
    }

    private static func nextDifferentVoice(
        from index: Int, in segments: [Transcript.Segment]
    ) -> String? {
        let origin = segments[index]
        for candidate in segments[(index + 1)...] {
            guard candidate.start_ms - origin.end_ms <= neighbourWindowMs else { return nil }
            guard let id = candidate.speaker_id, !id.isEmpty else { continue }
            guard isSubstantial(candidate.text) else { continue }
            if id != origin.speaker_id { return id }
        }
        return nil
    }

    private static func previousDifferentVoice(
        from index: Int, in segments: [Transcript.Segment]
    ) -> String? {
        let origin = segments[index]
        for candidate in segments[..<index].reversed() {
            guard origin.start_ms - candidate.end_ms <= neighbourWindowMs else { return nil }
            guard let id = candidate.speaker_id, !id.isEmpty else { continue }
            guard isSubstantial(candidate.text) else { continue }
            if id != origin.speaker_id { return id }
        }
        return nil
    }
}
