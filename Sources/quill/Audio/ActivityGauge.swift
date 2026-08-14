import AVFoundation
import Foundation

/// Frame tally for a live tap: how much audio arrived and when the last
/// buffer landed. Written from render threads, read from main.
final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var last: Date?

    func add(_ count: Int) {
        lock.lock()
        frames += count
        last = Date()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var lastAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

/// Tracks when a live track last carried real signal. Written from audio
/// render threads, read by the main-actor ticker deciding whether a silence
/// gap marks a meeting boundary — hence the lock.
final class ActivityGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLoudAt: Date?

    func note(peak: Float, threshold: Float) {
        guard peak >= threshold else { return }
        lock.lock()
        lastLoudAt = Date()
        lock.unlock()
    }

    var value: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastLoudAt
    }

    /// Strided peak — every 16th frame is plenty to answer "is anyone
    /// making sound", at a fraction of the cost of a full scan.
    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        var i = 0
        while i < frames {
            for channel in 0..<channels {
                peak = max(peak, abs(data[channel][i]))
            }
            i += 16
        }
        return peak
    }
}
