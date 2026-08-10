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
    /// recording, the feather turns red and a live elapsed counter sits next
    /// to it — recording should be obvious at a glance, not something you
    /// open the menu to discover. Call once a second while recording.
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
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
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
    /// recording, unread dot while something's waiting — both red, both
    /// next to the feather.
    private func renderButton() {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString()
        if recording {
            title.append(NSAttributedString(
                string: " \(elapsedText ?? "0:00")",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.systemRed,
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
        refreshUnread()
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

        let projects = Project.all(in: projectsRoot)
        for meeting in meetings {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.tag = Self.meetingTag
            item.attributedTitle = Self.meetingTitle(meeting)
            item.submenu = submenu(for: meeting, projects: projects)
            menu.insertItem(item, at: index)
            index += 1
        }

        let trailing = NSMenuItem.separator()
        trailing.tag = Self.meetingTag
        menu.insertItem(trailing, at: index)
    }

    private static func meetingTitle(_ meeting: Meeting) -> NSAttributedString {
        let title = NSMutableAttributedString()
        if meeting.isUnread {
            title.append(NSAttributedString(
                string: "● ", attributes: [.foregroundColor: NSColor.systemRed]
            ))
        }
        title.append(NSAttributedString(string: meeting.title))
        if !meeting.hasTranscript {
            title.append(NSAttributedString(
                string: "  (no transcript yet)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
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

    @objc private func openMeetingFolderClicked(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        Self.meeting(at: dir).markRead()
        NSWorkspace.shared.open(dir)
        refreshUnread()
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
