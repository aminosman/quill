import AVFoundation
import FluidAudio
import Foundation

/// Speaker diarization ("who spoke when") via FluidAudio's Core ML pyannote
/// port — segmentation + 256-dim speaker embeddings, on-device. Models
/// download once into FluidAudio's managed cache, like the ASR models.
///
/// Only the system track needs this: it carries every remote participant
/// mixed together. The mic track is one person by construction, so quill
/// never asks a model who was talking on it.
actor DiarizationEngine {
    struct Turn {
        /// The model's per-meeting speaker number. Meaningless across
        /// meetings, but authoritative *within* one — it's the output of a
        /// clustering pass over the whole recording, so it beats matching
        /// individual turns to a library one at a time.
        let localID: String
        let start: TimeInterval
        let end: TimeInterval
        let embedding: [Float]
        let quality: Float

        var seconds: Double { max(end - start, 0) }
    }

    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL)

        var description: String {
            switch self {
            case .notPrepared: return "diarization engine used before prepare()"
            case .unreadableAudio(let url): return "unreadable audio \(url.lastPathComponent)"
            }
        }
    }

    private var manager: DiarizerManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: consume models)
        self.manager = manager
    }

    /// Turns, in time order, with one embedding each. Consecutive turns the
    /// model assigned to the same local speaker are merged so downstream
    /// matching sees whole utterances rather than 10-second chunks.
    func diarize(_ audio: URL) async throws -> [Turn] {
        guard let manager else { throw EngineError.notPrepared }
        let samples = try Self.monoSamples16k(from: audio)
        guard samples.count > 16_000 else { return [] }

        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
        let ordered = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        var turns: [Turn] = []
        var currentID: String?
        for segment in ordered {
            let turn = Turn(
                localID: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                embedding: segment.embedding,
                quality: segment.qualityScore
            )
            if segment.speakerId == currentID, let last = turns.last,
               turn.start - last.end < 1.0 {
                // Same voice, no real gap: extend, keeping the longer
                // utterance's embedding (more audio, better centroid).
                turns[turns.count - 1] = Turn(
                    localID: last.localID,
                    start: last.start,
                    end: turn.end,
                    embedding: turn.seconds > last.seconds ? turn.embedding : last.embedding,
                    quality: max(turn.quality, last.quality)
                )
            } else {
                turns.append(turn)
                currentID = segment.speakerId
            }
        }
        return turns
    }

    func release() async {
        manager?.cleanup()
        manager = nil
    }

    /// Decode any input file to the 16 kHz mono float samples the models
    /// expect. AVAudioConverter handles both the sample-rate change and the
    /// downmix in one pass.
    private static func monoSamples16k(from url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            throw EngineError.unreadableAudio(url)
        }
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw EngineError.unreadableAudio(url) }

        let chunkFrames: AVAudioFrameCount = 16_384
        guard
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
        else { throw EngineError.unreadableAudio(url) }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * 16_000 / file.processingFormat.sampleRate))

        while true {
            input.frameLength = 0
            do {
                try file.read(into: input, frameCount: chunkFrames)
            } catch {
                break
            }
            if input.frameLength == 0 { break }

            let ratio = target.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                break
            }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            if conversionError != nil { break }
            if let data = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: data, count: Int(output.frameLength)
                ))
            }
        }
        return samples
    }
}
