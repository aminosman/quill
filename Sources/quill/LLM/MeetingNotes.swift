import Foundation

/// Turns a finished transcript into readable notes: a title, a summary, key
/// points, decisions and action items, plus the project the meeting belongs
/// to. Written to summary.md beside the transcript.
///
/// Long meetings are handled by whichever route the active model affords. A
/// model that can read the whole transcript does so in one pass — measured on
/// real meetings, that produces notes citing actual numbers and commitments.
/// A small-context model gets the transcript in pieces and its notes are
/// stitched, which is noticeably weaker but still better than nothing.
struct MeetingNotes {
    var title: String
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actions: [String]
    var project: String?

    private static let schema = JSONSchema([
        ("title", .string(description: "A 6-10 word title naming the actual topic")),
        ("summary", .string(description: "3-6 sentences: what was discussed and where it landed")),
        ("key_points", .stringArray(description: "Concrete points with specifics — numbers, tools, companies")),
        ("decisions", .stringArray(description: "Decisions made or commitments given; empty if none")),
        ("action_items", .stringArray(description: "Tasks someone agreed to do, with who; empty if none")),
        ("project", .string(description: "Exact project name from the catalog, or NONE")),
    ])

    private static let system = """
    You write meeting notes from a transcript. Be specific and factual: keep real numbers, tool and \
    company names, problems and commitments. Skip greetings, small talk and filler entirely. Never \
    invent anything — if the transcript does not say it, leave it out. Also pick which project from \
    the catalog the meeting is about, or NONE if none fits.
    """

    /// Generate notes, or nil when no model is configured/reachable.
    static func generate(
        transcript: Transcript,
        projects: [(name: String, description: String)],
        using engine: LLMEngine
    ) async -> MeetingNotes? {
        let catalog = projects.isEmpty
            ? "(no projects)"
            : projects.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let lines = transcript.segments.map { "\($0.label): \($0.text)" }
        let full = lines.joined(separator: "\n")

        // Budget: catalog + instructions + reply all share the window.
        let budget = max(engine.contextCharacters - catalog.count - 1_500, 1_200)
        if full.count <= budget {
            return await ask(engine: engine, catalog: catalog, transcript: full)
        }

        // Too long for one pass: summarize slices, then summarize the notes.
        var partials: [MeetingNotes] = []
        var chunk: [String] = []
        var size = 0
        for line in lines {
            if size + line.count > budget, !chunk.isEmpty {
                if let notes = await ask(
                    engine: engine, catalog: catalog, transcript: chunk.joined(separator: "\n")
                ) { partials.append(notes) }
                chunk = []
                size = 0
            }
            chunk.append(line)
            size += line.count
        }
        if !chunk.isEmpty,
           let notes = await ask(
               engine: engine, catalog: catalog, transcript: chunk.joined(separator: "\n")
           ) { partials.append(notes) }
        guard !partials.isEmpty else { return nil }

        let rolled = partials.flatMap(\.keyPoints).prefix(30).map { "- \($0)" }.joined(separator: "\n")
        let final = await ask(engine: engine, catalog: catalog, transcript: rolled, isDigest: true)
        return MeetingNotes(
            title: final?.title ?? partials[0].title,
            summary: final?.summary ?? partials.map(\.summary).joined(separator: " "),
            keyPoints: Array(partials.flatMap(\.keyPoints).prefix(20)),
            decisions: Array(partials.flatMap(\.decisions).prefix(10)),
            actions: Array(partials.flatMap(\.actions).prefix(10)),
            project: final?.project ?? partials.compactMap(\.project).first
        )
    }

    private static func ask(
        engine: LLMEngine, catalog: String, transcript: String, isDigest: Bool = false
    ) async -> MeetingNotes? {
        let label = isDigest ? "Notes taken during the meeting" : "Transcript"
        let prompt = "Project catalog:\n\(catalog)\n\n\(label):\n\n\(transcript)\n\nWrite the notes."
        guard let raw = try? await engine.respond(system: system, prompt: prompt, schema: schema)
        else { return nil }
        return parse(raw)
    }

    /// Providers without constrained decoding sometimes wrap JSON in prose or
    /// fences, so find the outermost object rather than trusting the shape.
    static func parse(_ raw: String) -> MeetingNotes? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func strings(_ key: String) -> [String] {
            (json[key] as? [Any])?.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 3 } ?? []
        }
        let project = (json["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingNotes(
            title: (json["title"] as? String) ?? "",
            summary: (json["summary"] as? String) ?? "",
            keyPoints: strings("key_points"),
            decisions: strings("decisions"),
            actions: strings("action_items"),
            project: (project?.isEmpty == false && project?.uppercased() != "NONE") ? project : nil
        )
    }

    func write(to dir: URL, engineName: String) {
        var lines = ["# \(title.isEmpty ? dir.lastPathComponent : title)", ""]
        if !summary.isEmpty { lines += [summary, ""] }
        func section(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("## \(heading)")
            lines += items.map { "- \($0)" }
            lines.append("")
        }
        section("Key points", keyPoints)
        section("Decisions", decisions)
        section("Action items", actions)
        if let project { lines += ["filed under: \(project)", ""] }
        lines.append("<sub>generated locally by \(engineName) — verify before relying on it</sub>")
        try? Data(lines.joined(separator: "\n").utf8)
            .write(to: dir.appendingPathComponent("summary.md"), options: .atomic)
    }
}
