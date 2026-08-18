import Foundation

/// A finished session as the menu sees it. Unread state is an `.unread`
/// marker file in the session folder — created when the transcript lands,
/// removed on first interaction — so it survives restarts and stays greppable.
struct Meeting {
    let dir: URL
    let hasTranscript: Bool
    let isUnread: Bool
    let durationSeconds: Int?

    var name: String { dir.lastPathComponent }

    private static let unreadMarker = ".unread"

    /// Finished sessions (meta.json exists), newest first. Folder names sort
    /// chronologically, so recency is a name sort.
    static func recent(in root: URL, limit: Int) -> [Meeting] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { dir in
                Meeting(
                    dir: dir,
                    hasTranscript: fm.fileExists(
                        atPath: dir.appendingPathComponent("transcript.md").path
                    ),
                    isUnread: fm.fileExists(
                        atPath: dir.appendingPathComponent(unreadMarker).path
                    ),
                    durationSeconds: readDuration(dir)
                )
            }
    }

    /// Whether any finished session anywhere in the root is still unread —
    /// drives the red dot on the status item.
    static func anyUnread(in root: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return entries.contains {
            fm.fileExists(atPath: $0.appendingPathComponent(unreadMarker).path)
        }
    }

    /// Called by the transcription pipeline when a session becomes readable.
    static func markUnread(_ dir: URL) {
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(unreadMarker).path, contents: nil
        )
    }

    func markRead() {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.unreadMarker))
    }

    /// "Aug 10, 3:02 PM · 42m" — parsed from the folder name, falling back to
    /// the raw name for anything that doesn't match the session format.
    var title: String {
        guard name.count >= 15,
              let date = Self.folderFormat.date(from: String(name.prefix(15)))
        else { return name }
        var text = Self.titleFormat.string(from: date)
        if let s = durationSeconds, s > 0 {
            let h = s / 3600, m = (s % 3600 + 59) / 60
            text += h > 0 ? " · \(h)h \(m)m" : " · \(m)m"
        }
        return text
    }

    private static func readDuration(_ dir: URL) -> Int? {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["duration_seconds"] as? Int
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let titleFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()
}

/// A project is any visible subdirectory of the projects root (~/Projects by
/// default). Linking a meeting symlinks its session folder into the project's
/// `meetings/` directory, created on first link. Recency is the meetings
/// directory's mtime — adding or removing a link touches it for free — so the
/// most recently used project sorts first with no state file.
struct Project {
    let dir: URL

    var name: String { dir.lastPathComponent }
    var meetingsDir: URL { dir.appendingPathComponent("meetings", isDirectory: true) }

    /// All projects, most recently linked-to first, never-linked ones after
    /// in name order.
    static func all(in root: URL) -> [Project] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(Project.init)
            .sorted { a, b in
                switch (a.lastUsed, b.lastUsed) {
                case (let x?, let y?): return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
    }

    private var lastUsed: Date? {
        try? FileManager.default.attributesOfItem(atPath: meetingsDir.path)[.modificationDate]
            as? Date
    }

    private func link(for meeting: Meeting) -> URL {
        meetingsDir.appendingPathComponent(meeting.name)
    }

    func isLinked(_ meeting: Meeting) -> Bool {
        // lstat-style check: a symlink whose target vanished still counts as
        // linked, so toggling it off still works.
        (try? link(for: meeting).checkResourceIsReachable()) == true
            || (try? FileManager.default.destinationOfSymbolicLink(
                atPath: link(for: meeting).path)) != nil
    }

    /// Outcome of an auto-file pass: the single project that won, or the
    /// candidates that were too close (or too weak) to call — the user
    /// resolves those by hand.
    struct AutoFileResult {
        let filed: String?
        let ambiguous: [String]
    }

    /// Projects enabled for meetings: the "meetingable" allowlist from
    /// config, or every subdirectory when no list has been saved yet.
    static func enabled(in root: URL) -> [Project] {
        let projects = all(in: root)
        guard let names = Config.meetingProjects() else { return projects }
        let allowed = Set(names)
        return projects.filter { allowed.contains($0.name) }
    }

    /// Auto-file a transcribed session into the single meetingable project
    /// whose name is mentioned most — and strictly more than any other.
    /// Matching is case-insensitive on whole words with separators
    /// normalized, so project "billing-service" matches spoken "billing
    /// service"; names shorter than 4 characters are skipped. A clear win
    /// needs at least two mentions; a tie at the top, or nothing but
    /// single mentions, is reported as ambiguous instead of filed.
    static func autoFile(_ sessionDir: URL, projectsRoot: URL) -> AutoFileResult {
        guard
            let data = try? Data(
                contentsOf: sessionDir.appendingPathComponent("transcript.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let segments = json["segments"] as? [[String: Any]]
        else { return AutoFileResult(filed: nil, ambiguous: []) }

        let spoken = " " + normalize(segments.compactMap { $0["text"] as? String }
            .joined(separator: " ")) + " "
        let meeting = Meeting(
            dir: sessionDir, hasTranscript: true, isUnread: true, durationSeconds: nil
        )

        let counts = enabled(in: projectsRoot)
            .compactMap { project -> (project: Project, count: Int)? in
                let phrase = normalize(project.name)
                guard phrase.count >= 4 else { return nil }
                let count = mentions(of: " \(phrase) ", in: spoken)
                return count > 0 ? (project, count) : nil
            }
            .sorted { $0.count > $1.count }

        guard let top = counts.first, top.count >= 2 else {
            // Nothing spoken twice — every mention is too weak to file on.
            return AutoFileResult(filed: nil, ambiguous: counts.map(\.project.name))
        }
        let tied = counts.filter { $0.count == top.count }
        guard tied.count == 1 else {
            return AutoFileResult(filed: nil, ambiguous: tied.map(\.project.name))
        }
        if top.project.isLinked(meeting) || top.project.toggleLink(meeting) {
            return AutoFileResult(filed: top.project.name, ambiguous: [])
        }
        return AutoFileResult(filed: nil, ambiguous: [])
    }

    /// Lowercase, every non-alphanumeric run collapsed to a single space.
    private static func normalize(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func mentions(of needle: String, in haystack: String) -> Int {
        var count = 0
        var start = haystack.startIndex
        while let found = haystack.range(of: needle, range: start..<haystack.endIndex) {
            count += 1
            // Step back one so a trailing space can serve as the next
            // match's leading space ("… quill quill …").
            start = haystack.index(before: found.upperBound)
        }
        return count
    }

    /// One-line description for the LLM catalog: the README's first real
    /// line, else the notable subdirectories. Bare codenames like "mars" tell
    /// a model nothing — with descriptions, classification actually works.
    var description: String {
        let readme = dir.appendingPathComponent("README.md")
        if let text = try? String(contentsOf: readme, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("!"),
                      !trimmed.hasPrefix("[")
                else { continue }
                return String(trimmed.prefix(160))
            }
        }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { !$0.hasPrefix(".") && !$0.contains(".") }
            .prefix(6)
            .joined(separator: ", ")
        return children.map { "contains: \($0)" } ?? ""
    }

    /// Drop every project's link to a meeting — for when the recording
    /// itself is deleted, so no dangling symlinks stay behind.
    static func removeAllLinks(to meeting: Meeting, in root: URL) {
        for project in all(in: root) where project.isLinked(meeting) {
            project.toggleLink(meeting)
        }
    }

    /// Link a meeting to the named project if it exists and is meetingable.
    static func link(meeting: Meeting, toProjectNamed name: String, root: URL) -> String? {
        guard let project = enabled(in: root).first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) else { return nil }
        if project.isLinked(meeting) { return project.name }
        return project.toggleLink(meeting) ? project.name : nil
    }

    /// Link or unlink the meeting. Returns whether it is linked afterwards.
    @discardableResult
    func toggleLink(_ meeting: Meeting) -> Bool {
        let fm = FileManager.default
        let url = link(for: meeting)
        if isLinked(meeting) {
            try? fm.removeItem(at: url)
            return false
        }
        do {
            try fm.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: url, withDestinationURL: meeting.dir)
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "linking \(meeting.name) → \(name) failed: \(error)\n".utf8
            ))
            return false
        }
    }
}
