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

    /// Drop every project's link to a meeting — for when the recording
    /// itself is deleted, so no dangling symlinks stay behind.
    static func removeAllLinks(to meeting: Meeting, in root: URL) {
        for project in all(in: root) where project.isLinked(meeting) {
            project.toggleLink(meeting)
        }
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
