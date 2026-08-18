import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
///
/// Besides the record controls, the menu lists the last five meetings, each
/// with a submenu to open it or link it into a project's `meetings/` folder.
/// A red dot on the feather means a finished meeting hasn't been looked at
/// yet. The meetings section is rebuilt from the filesystem every time the
/// menu opens — no cached state to fall out of sync.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let recordingsRoot: URL
    private var projectsRoot: URL

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let autoRecordItem: NSMenuItem
    private let meetingsAnchor: NSMenuItem
    private var meetingableItem: NSMenuItem!
    private var notesModelItem: NSMenuItem!
    /// Set while a download runs so the menu can show progress instead of a
    /// stale list, and so a second click can't start a parallel download.
    private var modelStatus: String?
    private var recording = false
    private var elapsedText: String?
    private var unread = false

    var onToggle: (() -> Void)?
    var onToggleAutoRecord: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Marker distinguishing rebuilt-per-open meeting rows from fixed items.
    private static let meetingTag = 7

    init(recordingsRoot: URL, projectsRoot: URL) {
        self.recordingsRoot = recordingsRoot
        self.projectsRoot = projectsRoot

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        autoRecordItem = NSMenuItem(
            title: "Auto-record on mic use",
            action: #selector(autoRecordClicked),
            keyEquivalent: "a"
        )
        menu.addItem(autoRecordItem)

        menu.addItem(.separator())

        // Meeting rows are inserted above this hidden anchor on each open.
        meetingsAnchor = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        meetingsAnchor.isHidden = true
        menu.addItem(meetingsAnchor)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        let chooseProjects = NSMenuItem(
            title: "Choose projects folder…",
            action: #selector(chooseProjectsFolderClicked),
            keyEquivalent: ""
        )
        menu.addItem(chooseProjects)

        notesModelItem = NSMenuItem(title: "Meeting notes", action: nil, keyEquivalent: "")
        notesModelItem.submenu = NSMenu()
        notesModelItem.submenu?.autoenablesItems = false
        menu.addItem(notesModelItem)

        meetingableItem = NSMenuItem(title: "Meetingable projects", action: nil, keyEquivalent: "")
        meetingableItem.submenu = NSMenu()
        meetingableItem.submenu?.autoenablesItems = false
        menu.addItem(meetingableItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        super.init()

        for item in [toggleItem, autoRecordItem, openFolder, chooseProjects, quit] {
            item.target = self
        }
        menu.delegate = self
        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Feather.menuImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
        rebuildMeetings()
        refreshUnread()
    }

    /// Reflect recording state in the menu bar and menu item titles. While
    /// recording, a live elapsed counter sits next to the feather —
    /// recording should be obvious at a glance, not something you open the
    /// menu to discover. Call once a second while recording.
    func update(recording: Bool, elapsed: String?) {
        self.recording = recording
        self.elapsedText = elapsed
        renderButton()
        if recording {
            // Disabled items gray out plain titles but render attributed ones
            // as given — that's what lets the dot stay red. Monospaced digits
            // keep the ticking counter from jiggling the layout.
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(
                string: "● ", attributes: [.foregroundColor: NSColor.systemRed]
            ))
            title.append(NSAttributedString(
                string: "Recording",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            ))
            title.append(NSAttributedString(
                string: "   \(elapsed ?? "0:00")",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            stateLabel.attributedTitle = title
        } else {
            stateLabel.attributedTitle = nil
            stateLabel.title = "Idle"
        }
        toggleItem.title = recording ? "Stop recording" : "Start recording"
    }

    /// Reflect the auto-record arm state as a checkmark on the menu item.
    func setAutoRecord(_ enabled: Bool) {
        autoRecordItem.state = enabled ? .on : .off
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Re-derive the red unread dot from the filesystem. Call whenever a
    /// transcript may have landed or been read.
    func refreshUnread() {
        unread = Meeting.anyUnread(in: recordingsRoot)
        renderButton()
    }

    /// Compose the status button title: live elapsed counter while
    /// recording, red dot while something's unread. No explicit color on
    /// the counter and no tint on the feather — menu bar vibrancy composites
    /// explicit colors into illegible near-black; only the adaptive template
    /// style renders white like every other status item.
    private func renderButton() {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString()
        if recording {
            title.append(NSAttributedString(
                string: " \(elapsedText ?? "0:00")",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                ]
            ))
        }
        if unread {
            title.append(NSAttributedString(
                string: " ●",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 8),
                    .baselineOffset: 3,
                ]
            ))
        }
        button.attributedTitle = title
    }

    // MARK: - Recent meetings

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildMeetings()
        rebuildMeetingable()
        rebuildModels()
        refreshUnread()
    }

    /// Model picker: choosing an entry downloads and configures it, so the
    /// only step a user takes is deciding how much disk and memory to spend.
    private func rebuildModels() {
        guard let sub = notesModelItem.submenu else { return }
        sub.removeAllItems()

        if let modelStatus {
            let item = NSMenuItem(title: modelStatus, action: nil, keyEquivalent: "")
            item.isEnabled = false
            sub.addItem(item)
            return
        }

        let active = ModelCatalog.active
        let recommended = ModelCatalog.recommended
        let installed = Set(
            ModelInstaller.ollamaPath().map(ModelInstaller.installedModels(ollama:)) ?? []
        )
        for option in ModelCatalog.options {
            var detail: [String] = []
            if !option.isOff, !option.isBuiltIn {
                detail.append(installed.contains(option.id) ? "installed" : option.sizeText)
            }
            if option.id == recommended.id { detail.append("recommended") }
            if !option.isOff, !option.isBuiltIn,
               option.requiresMemoryGB > ModelCatalog.memoryGB {
                detail.append("needs \(Int(option.requiresMemoryGB)) GB")
            }
            let title = detail.isEmpty
                ? option.label
                : "\(option.label)  ·  \(detail.joined(separator: ", "))"
            let item = NSMenuItem(
                title: title, action: #selector(modelClicked(_:)), keyEquivalent: ""
            )
            item.target = self
            item.state = option.id == active.id ? .on : .off
            item.representedObject = option.id
            item.toolTip = option.blurb
            sub.addItem(item)
        }
    }

    /// Checklist of every project directory; checked = meetingable. Only
    /// checked projects appear in link menus and can auto-match.
    private func rebuildMeetingable() {
        guard let sub = meetingableItem.submenu else { return }
        sub.removeAllItems()
        let enabledNames = Set(Project.enabled(in: projectsRoot).map(\.name))
        for project in Project.all(in: projectsRoot) {
            let item = NSMenuItem(
                title: project.name,
                action: #selector(meetingableClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = enabledNames.contains(project.name) ? .on : .off
            item.representedObject = project.name
            sub.addItem(item)
        }
        meetingableItem.isHidden = sub.items.isEmpty
    }

    private func rebuildMeetings() {
        while let stale = menu.items.first(where: { $0.tag == Self.meetingTag }) {
            menu.removeItem(stale)
        }

        let meetings = Meeting.recent(in: recordingsRoot, limit: 5)
        guard !meetings.isEmpty else { return }
        var index = menu.index(of: meetingsAnchor)

        let header = NSMenuItem(title: "Recent meetings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.tag = Self.meetingTag
        menu.insertItem(header, at: index)
        index += 1

        let projects = Project.enabled(in: projectsRoot)
        for meeting in meetings {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.tag = Self.meetingTag
            item.attributedTitle = Self.meetingTitle(meeting)
            item.toolTip = meeting.summarySnippet
            item.submenu = submenu(for: meeting, projects: projects)
            menu.insertItem(item, at: index)
            index += 1
        }

        let trailing = NSMenuItem.separator()
        trailing.tag = Self.meetingTag
        menu.insertItem(trailing, at: index)
    }

    /// A row you can act on at a glance: what the meeting was about, then
    /// when. The date alone is useless when three calls share an afternoon,
    /// but the title has to be clipped or one verbose summary stretches the
    /// whole menu. Where a meeting is filed lives in the submenu, as a
    /// checkmark, rather than widening every row.
    private static func meetingTitle(_ meeting: Meeting) -> NSAttributedString {
        let title = NSMutableAttributedString()
        if meeting.isUnread {
            title.append(NSAttributedString(
                string: "● ", attributes: [.foregroundColor: NSColor.systemRed]
            ))
        }

        let secondary: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ]
        if let label = meeting.label {
            let clipped = label.count > 50 ? String(label.prefix(49)) + "…" : label
            title.append(NSAttributedString(
                string: clipped,
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: NSFont.systemFontSize, weight: .medium)
                ]
            ))
            title.append(NSAttributedString(string: "   \(meeting.title)", attributes: secondary))
        } else {
            // No notes yet — the timestamp is all there is.
            title.append(NSAttributedString(string: meeting.title))
            if !meeting.hasTranscript {
                title.append(NSAttributedString(string: "   transcribing…", attributes: secondary))
            }
        }
        return title
    }

    private func submenu(for meeting: Meeting, projects: [Project]) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let open = NSMenuItem(
            title: "View transcript",
            action: #selector(openTranscriptClicked(_:)),
            keyEquivalent: ""
        )
        open.target = self
        open.isEnabled = meeting.hasTranscript
        open.representedObject = meeting.dir
        sub.addItem(open)

        if FileManager.default.fileExists(
            atPath: meeting.dir.appendingPathComponent("summary.md").path
        ) {
            let notes = NSMenuItem(
                title: "Open notes",
                action: #selector(openNotesClicked(_:)),
                keyEquivalent: ""
            )
            notes.target = self
            notes.representedObject = meeting.dir
            sub.addItem(notes)
        }

        let folder = NSMenuItem(
            title: "Open folder",
            action: #selector(openMeetingFolderClicked(_:)),
            keyEquivalent: ""
        )
        folder.target = self
        folder.representedObject = meeting.dir
        sub.addItem(folder)

        if !projects.isEmpty {
            sub.addItem(.separator())
            let label = NSMenuItem(title: "Link to project", action: nil, keyEquivalent: "")
            label.isEnabled = false
            sub.addItem(label)

            for project in projects {
                let item = NSMenuItem(
                    title: project.name,
                    action: #selector(projectClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.state = project.isLinked(meeting) ? .on : .off
                item.representedObject = [meeting.dir, project.dir]
                sub.addItem(item)
            }
        }
        return sub
    }

    /// Reconstruct the Meeting for a menu action from its session dir. Menu
    /// items are rebuilt on every open, so the dir always exists moments
    /// before — a vanished dir just makes the action a no-op.
    private static func meeting(at dir: URL) -> Meeting {
        Meeting(dir: dir, hasTranscript: true, isUnread: false, durationSeconds: nil)
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func autoRecordClicked() { onToggleAutoRecord?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }

    /// Folder picker for the projects root, persisted to the config file.
    /// Menus and viewer windows read `projectsRoot` at open time, so the new
    /// choice takes effect immediately.
    @objc private func chooseProjectsFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = projectsRoot
        panel.message = "Choose the folder whose subfolders are your projects."
        panel.prompt = "Use as Projects Folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectsRoot = url
        Config.setProjectsDir(url)
    }

    @objc private func openTranscriptClicked(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        Self.meeting(at: dir).markRead()
        TranscriptViewer.show(meetingDir: dir, projectsRoot: projectsRoot) { [weak self] in
            self?.refreshUnread()
        }
        refreshUnread()
    }

    @objc private func openNotesClicked(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        Self.meeting(at: dir).markRead()
        NSWorkspace.shared.open(dir.appendingPathComponent("summary.md"))
        refreshUnread()
    }

    @objc private func openMeetingFolderClicked(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        Self.meeting(at: dir).markRead()
        NSWorkspace.shared.open(dir)
        refreshUnread()
    }

    @objc private func modelClicked(_ sender: NSMenuItem) {
        guard modelStatus == nil,
              let id = sender.representedObject as? String,
              let option = ModelCatalog.option(id: id),
              option.id != ModelCatalog.active.id
        else { return }

        modelStatus = "Setting up \(option.label)…"
        if !option.isOff, !option.isBuiltIn {
            notifyUser(
                title: "quill — setting up \(option.label)",
                body: "Downloading \(option.sizeText). Notes will use it when it's ready."
            )
        }
        DispatchQueue.global(qos: .utility).async {
            ModelInstaller.activate(option) { progress in
                Task { @MainActor [weak self] in
                    switch progress {
                    case .message(let text):
                        self?.modelStatus = text
                    case .downloading(let percent):
                        self?.modelStatus = "Downloading \(option.label)… \(percent)%"
                    case .done(let text):
                        self?.modelStatus = nil
                        notifyUser(title: "quill — model ready", body: text)
                    case .failed(let text):
                        self?.modelStatus = nil
                        notifyUser(title: "quill — model setup failed", body: text)
                    }
                }
            }
        }
    }

    @objc private func meetingableClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var names = Set(Project.enabled(in: projectsRoot).map(\.name))
        if names.contains(name) { names.remove(name) } else { names.insert(name) }
        Config.setMeetingProjects(Array(names))
    }

    @objc private func projectClicked(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        let meeting = Self.meeting(at: pair[0])
        let linked = Project(dir: pair[1]).toggleLink(meeting)
        // Filing a meeting counts as reading it.
        if linked { meeting.markRead() }
        refreshUnread()
    }
}
