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
        let watched: Bool
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
    private var pendingStart: Timer?
    private var pendingStop: Timer?
    /// Non-nil between onMicActive and onMicIdle. Suppresses re-triggering
    /// while the same call is still holding the mic (e.g. after a manual stop).
    private var announcedBundleID: String?

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

        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
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
                if proc.watched { reevaluate() }
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
    }

    private func refresh(process id: AudioObjectID) {
        if isRunningInput(id) {
            guard active[id] == nil else { return }
            let bundleID = bundleID(of: id)
            let label = bundleID.isEmpty ? "pid \(pid(of: id))" : bundleID
            let watched = isWatched(bundleID)
            active[id] = Proc(label: label, bundleID: bundleID, watched: watched)
            log("mic on: \(label)\(watched ? "" : " (not in auto_record.apps)")")
            if watched { reevaluate() }
        } else if let proc = active.removeValue(forKey: id) {
            log("mic off: \(proc.label)")
            if proc.watched { reevaluate() }
        }
    }

    // MARK: - Debounced state machine

    private func reevaluate() {
        let held = active.values.contains(where: \.watched)
        if held {
            pendingStop?.invalidate()
            pendingStop = nil
            if announcedBundleID == nil, pendingStart == nil {
                pendingStart = Timer.scheduledTimer(withTimeInterval: startDelay, repeats: false) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.fireActiveIfStillHeld() }
                }
            }
        } else {
            pendingStart?.invalidate()
            pendingStart = nil
            if announcedBundleID != nil, pendingStop == nil {
                pendingStop = Timer.scheduledTimer(withTimeInterval: stopGrace, repeats: false) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.fireIdleIfStillClear() }
                }
            }
        }
    }

    private func fireActiveIfStillHeld() {
        pendingStart = nil
        guard announcedBundleID == nil,
              let proc = active.values.first(where: \.watched)
        else { return }
        announcedBundleID = proc.bundleID
        onMicActive?(proc.bundleID)
    }

    private func fireIdleIfStillClear() {
        pendingStop = nil
        guard announcedBundleID != nil, !active.values.contains(where: \.watched) else { return }
        announcedBundleID = nil
        onMicIdle?()
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
    /// renderer bundles) count as their parent app.
    private func isWatched(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return watchlist.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
