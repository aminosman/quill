import AppKit
import SwiftUI

/// Floating transcript viewer: read a meeting, file it to projects, or trash
/// the whole recording. One window per session, brought forward on reopen.
/// SwiftUI content in a plain NSWindow — no scene machinery, so it coexists
/// with the `.accessory` menu-bar lifecycle.
@MainActor
enum TranscriptViewer {
    private struct Registration {
        let window: NSWindow
        let closeToken: NSObjectProtocol
    }

    private static var open: [URL: Registration] = [:]

    /// `onChange` fires after anything that affects the menu (read state,
    /// project links, deletion) so the caller can refresh the unread dot.
    static func show(meetingDir: URL, projectsRoot: URL, onChange: @escaping () -> Void) {
        if let existing = open[meetingDir] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let doc = TranscriptDoc(dir: meetingDir)
        let root = TranscriptView(
            doc: doc,
            projectsRoot: projectsRoot,
            onChange: onChange,
            requestClose: { open[meetingDir]?.window.close() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = doc.title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()

        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                if let gone = open.removeValue(forKey: meetingDir) {
                    NotificationCenter.default.removeObserver(gone.closeToken)
                }
            }
        }
        open[meetingDir] = Registration(window: window, closeToken: token)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The transcript as loaded from transcript.json, plus display strings.
struct TranscriptDoc {
    struct Segment: Identifiable {
        let id: Int
        let speaker: String
        let startMs: Int
        let text: String

        var clock: String {
            let total = startMs / 1000
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            return h > 0
                ? String(format: "%d:%02d:%02d", h, m, s)
                : String(format: "%d:%02d", m, s)
        }
    }

    let dir: URL
    let title: String
    let subtitle: String
    let segments: [Segment]

    var meeting: Meeting {
        Meeting(dir: dir, hasTranscript: true, isUnread: false, durationSeconds: nil)
    }

    init(dir: URL) {
        self.dir = dir
        let meeting = Meeting.recent(in: dir.deletingLastPathComponent(), limit: 50)
            .first { $0.dir.lastPathComponent == dir.lastPathComponent }
        title = meeting?.title ?? dir.lastPathComponent

        var engineLine = ""
        var loaded: [Segment] = []
        if let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let engine = json["engine"] as? String {
                let model = json["model"] as? String
                engineLine = "transcribed by \(engine)\(model.map { " (\($0))" } ?? "")"
            }
            let raw = json["segments"] as? [[String: Any]] ?? []
            loaded = raw.enumerated().compactMap { index, seg in
                guard let text = seg["text"] as? String else { return nil }
                return Segment(
                    id: index,
                    speaker: seg["speaker"] as? String ?? "?",
                    startMs: seg["start_ms"] as? Int ?? 0,
                    text: text
                )
            }
        }
        segments = loaded
        subtitle = engineLine.isEmpty ? dir.lastPathComponent : engineLine
    }
}

struct TranscriptView: View {
    let doc: TranscriptDoc
    let projectsRoot: URL
    let onChange: () -> Void
    let requestClose: () -> Void

    @State private var filter = ""
    @State private var linked: Set<String> = []
    @State private var confirmingDelete = false

    private var filtered: [TranscriptDoc.Segment] {
        filter.isEmpty
            ? doc.segments
            : doc.segments.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear(perform: refreshLinks)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(doc.title).font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Text(doc.subtitle).font(.caption).foregroundStyle(.secondary)
                if !linked.isEmpty {
                    Text("filed: \(linked.sorted().joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            TextField("Filter transcript…", text: $filter)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if doc.segments.isEmpty {
                    Text("No transcript segments — the meeting may still be transcribing.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                } else if filtered.isEmpty {
                    Text("Nothing matches “\(filter)”.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
                ForEach(filtered) { seg in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(seg.clock)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .trailing)
                        Text(seg.speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(seg.speaker == "me" ? Color.blue : Color.orange)
                            .frame(width: 40, alignment: .leading)
                        Text(seg.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                ForEach(Project.enabled(in: projectsRoot), id: \.dir) { project in
                    Button {
                        project.toggleLink(doc.meeting)
                        doc.meeting.markRead()
                        refreshLinks()
                        onChange()
                    } label: {
                        if linked.contains(project.name) {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            } label: {
                Label("Link to project", systemImage: "folder.badge.plus")
            }
            .fixedSize()

            Button("Open folder") {
                NSWorkspace.shared.open(doc.dir)
            }

            Spacer()

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete recording…", systemImage: "trash")
            }
            .confirmationDialog(
                "Move this recording to the Trash?",
                isPresented: $confirmingDelete
            ) {
                Button("Move to Trash", role: .destructive, action: deleteRecording)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Audio, transcript, and any project links for “\(doc.title)” will be removed.")
            }
        }
        .padding()
    }

    private func refreshLinks() {
        // All projects, not just meetingable — an existing link to a since-
        // disabled project should still show as filed.
        linked = Set(
            Project.all(in: projectsRoot)
                .filter { $0.isLinked(doc.meeting) }
                .map(\.name)
        )
    }

    private func deleteRecording() {
        Project.removeAllLinks(to: doc.meeting, in: projectsRoot)
        try? FileManager.default.trashItem(at: doc.dir, resultingItemURL: nil)
        onChange()
        requestClose()
    }
}
