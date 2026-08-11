import CoreAudio
import Foundation

/// Watches the HAL's per-process audio objects (macOS 14+) to detect other
/// apps opening the microphone — Slack starting a huddle, a browser joining a
/// call — so a recording can start without a click. Purely observational: no
/// taps, no devices, no additional TCC permission.
///
/// Events are debounced. `onMicActive` fires only after a watched app has held
/// the mic for `startDelay`, which filters out permission prompts, dictation,
/// and quick voice searches. `onMicIdle` fires only after every watched app
/// has been off the mic for `stopGrace`, which rides out call drops and
/// rejoins without splitting the session.
///
/// Detection is listener-driven with a polling backstop: the HAL notifies
/// process-object device attach/detach (kAudioProcessPropertyDevices) but —
/// observed on macOS 15 — never posts change notifications for
/// kAudioProcessPropertyIsRunningInput itself. Wildcard listeners catch the
/// common start/stop-of-capture moments immediately; a slow poll of the
/// running-input flag (a few dozen scalar property reads) catches apps that
/// keep the device attached and merely toggle capture, like Slack between
/// huddles.
///
/// Every mic on/off transition — watched or not — is logged to stderr, so
/// finding the bundle ID for a new app to watch is just reading the log while
/// starting a call in it.
@MainActor
final class MicActivityMonitor {
    /// A watched app has held the mic for `startDelay`. Argument: its bundle ID.
    var onMicActive: ((String) -> Void)?
    /// No watched app has touched the mic for `stopGrace`.
    var onMicIdle: (() -> Void)?

    private struct Proc {
        let label: String
        let bundleID: String
        /// The watchlist entry this process matched, nil if unwatched. Helper
        /// processes share their parent's entry, so "which app holds the mic"
        /// compares equal across an app's processes.
        let watchEntry: String?
        var watched: Bool { watchEntry != nil }
    }

    private let watchlist: [String]
    private let startDelay: TimeInterval
    private let stopGrace: TimeInterval

    private let systemID = AudioObjectID(kAudioObjectSystemObject)
    /// HAL notifications are delivered synchronously to their queue. Taking
    /// them on .main deadlocks: starting our own capture makes AVFAudio
    /// dispatch_sync from main into CoreAudio while CoreAudio is waiting on
    /// main to deliver the very events that capture generated. A private
    /// queue that only ever hops to main *asynchronously* breaks the cycle.
    private let listenerQueue = DispatchQueue(label: "com.digimata.quill.mic-monitor")
    private var listListener: AudioObjectPropertyListenerBlock?
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var active: [AudioObjectID: Proc] = [:]
    private var pollTimer: Timer?
    private var wakeTimer: Timer?

    // State machine. All transitions are decided from these timestamps at
    // evaluation points (HAL events, the poll, wake timers) — never from a
    // timer having fired. A windowless agent's timers get deferred by App
    // Nap for minutes; a late evaluation with timestamps still makes the
    // right call, and a mic re-grab after a longer-than-grace gap closes the
    // old session retroactively instead of merging two meetings.
    /// Watchlist entry that owns the current announced session, nil when idle.
    private var announced: String?
    /// Continuous watched-hold start — the start-debounce clock.
    private var heldSince: Date?
    /// When the watched set last went empty — the stop-grace clock.
    private var idleSince: Date?

    init(watchlist: [String], startDelay: TimeInterval, stopGrace: TimeInterval) {
        self.watchlist = watchlist
        self.startDelay = startDelay
        self.stopGrace = stopGrace
    }

    /// Begin observing. Safe to call once; listener registrations live until
    /// process exit.
    func start() {
        guard listListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.syncProcessList() }
            }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(systemID, &address, listenerQueue, block)
        guard status == noErr else {
            log("mic monitor unavailable: process list listener failed (OSStatus \(status))")
            return
        }
        listListener = block
        syncProcessList()

        let poll = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        poll.tolerance = 0
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
    }

    // MARK: - Process tracking

    /// Reconcile listeners with the HAL's current process object list:
    /// processes appear here when they first touch audio and vanish on exit.
    private func syncProcessList() {
        let current = processObjectIDs()
        let currentSet = Set(current)

        for id in Array(listeners.keys) where !currentSet.contains(id) {
            if let block = listeners.removeValue(forKey: id) {
                var address = Self.wildcardAddress()
                AudioObjectRemovePropertyListenerBlock(id, &address, listenerQueue, block)
            }
            if let proc = active.removeValue(forKey: id) {
                log("mic off: \(proc.label) (exited)")
                if proc.watched { evaluate() }
            }
        }

        for id in current where listeners[id] == nil {
            // Wildcard, not IsRunningInput: the HAL doesn't notify that
            // selector, but device attach/detach events arrive and running
            // state is re-read on every event.
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.refresh(process: id)
                        self?.recheckSoon(id)
                    }
                }
            }
            var address = Self.wildcardAddress()
            if AudioObjectAddPropertyListenerBlock(id, &address, listenerQueue, block) == noErr {
                listeners[id] = block
            }
            refresh(process: id)
        }
    }

    /// Device attach can precede the running-input flip by a beat; one quick
    /// re-read shortly after an event closes that gap without waiting for the
    /// slow poll.
    private func recheckSoon(_ id: AudioObjectID) {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(process: id) }
        }
    }

    private func refreshAll() {
        for id in listeners.keys { refresh(process: id) }
        // Evaluate even when nothing changed — elapsed time is itself a
        // state change (debounce maturing, grace expiring).
        evaluate()
    }

    private func refresh(process id: AudioObjectID) {
        if isRunningInput(id) {
            guard active[id] == nil else { return }
            let bundleID = bundleID(of: id)
            let label = bundleID.isEmpty ? "pid \(pid(of: id))" : bundleID
            let entry = watchEntry(for: bundleID)
            active[id] = Proc(label: label, bundleID: bundleID, watchEntry: entry)
            log("mic on: \(label)\(entry == nil ? " (not in auto_record.apps)" : "")")
            if entry != nil { evaluate() }
        } else if let proc = active.removeValue(forKey: id) {
            log("mic off: \(proc.label)")
            if proc.watched { evaluate() }
        }
    }

    // MARK: - Timestamp-driven state machine

    private func evaluate() {
        let now = Date()
        let holders = active.values.filter(\.watched)

        if let holder = holders.first {
            if heldSince == nil { heldSince = now }

            if announced != nil {
                let gap = idleSince.map { now.timeIntervalSince($0) } ?? 0
                let announcedStillHolding = holders.contains { $0.watchEntry == announced }
                if gap >= stopGrace {
                    // The idle stretch before this grab outlasted the grace —
                    // that was a meeting boundary, however late we noticed.
                    log("mic re-grab after \(Int(gap))s idle — treating as a new meeting")
                    endAnnounced()
                    heldSince = now
                } else if !announcedStillHolding {
                    // Within grace, but a different app took the mic. A drop-
                    // and-rejoin comes back in the same app; a switch means a
                    // new meeting.
                    log("mic holder changed (\(announced ?? "?") → \(holder.watchEntry ?? "?")) — treating as a new meeting")
                    endAnnounced()
                    heldSince = now
                }
            }
            idleSince = nil

            if announced == nil {
                let heldFor = now.timeIntervalSince(heldSince ?? now)
                if heldFor >= startDelay {
                    announced = holder.watchEntry
                    onMicActive?(holder.bundleID)
                } else {
                    scheduleEvaluation(after: startDelay - heldFor)
                }
            }
        } else {
            heldSince = nil
            if idleSince == nil { idleSince = now }
            if announced != nil {
                let idleFor = now.timeIntervalSince(idleSince ?? now)
                if idleFor >= stopGrace {
                    endAnnounced()
                } else {
                    scheduleEvaluation(after: stopGrace - idleFor)
                }
            }
        }
    }

    private func endAnnounced() {
        announced = nil
        idleSince = nil
        onMicIdle?()
    }

    /// Wake timers only *prompt* an evaluation — they carry no decision, so
    /// a deferred or coalesced timer costs latency, never correctness. The
    /// 4s poll backstops them.
    private func scheduleEvaluation(after delay: TimeInterval) {
        wakeTimer?.invalidate()
        let timer = Timer(timeInterval: max(delay, 0.1) + 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    // MARK: - HAL property plumbing

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func wildcardAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertySelectorWildcard,
            mScope: kAudioObjectPropertyScopeWildcard,
            mElement: kAudioObjectPropertyElementWildcard
        )
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var list = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(systemID, &address, 0, nil, &size, &list) == noErr else {
            return []
        }
        return list
    }

    private func isRunningInput(_ id: AudioObjectID) -> Bool {
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
            && value != 0
    }

    private func bundleID(of id: AudioObjectID) -> String {
        var address = Self.address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return "" }
        return value.takeRetainedValue() as String
    }

    private func pid(of id: AudioObjectID) -> pid_t {
        var address = Self.address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    /// Prefix match so helper processes (com.google.Chrome.helper, Electron
    /// renderer bundles) count as their parent app's watchlist entry.
    private func watchEntry(for bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        return watchlist.first { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
