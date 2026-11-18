import Foundation

/// A stretch of detected speech, in seconds from the start of the clip.
public struct SpeechSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// Anything that can find speech in 16 kHz mono audio.
public protocol VoiceActivityDetector {
    var name: String { get }
    func speechSegments(in samples: [Float], sampleRate: Double) -> [SpeechSegment]
}

/// The gate's verdict on one recording.
public struct VADDecision: Equatable, Sendable {
    public var segments: [SpeechSegment]
    /// Total seconds of detected speech.
    public var speechSeconds: Double
    public var audioSeconds: Double
    /// True if the clip should be skipped (no transcription, nothing pasted).
    public var skip: Bool
    /// Sample range to transcribe: first speech minus padding to last speech plus padding.
    /// Silence inside the clip is kept, so no words are cut out.
    public var trimRange: Range<Int>

    public func trimmed(_ samples: [Float]) -> [Float] {
        let lower = max(0, min(trimRange.lowerBound, samples.count))
        let upper = max(lower, min(trimRange.upperBound, samples.count))
        return Array(samples[lower..<upper])
    }
}

public enum VADGate {
    /// Decides whether a clip has enough speech, and where to trim it.
    public static func decide(
        segments: [SpeechSegment],
        sampleCount: Int,
        sampleRate: Double,
        minSpeechSeconds: Double,
        padSeconds: Double
    ) -> VADDecision {
        let audioSeconds = Double(sampleCount) / sampleRate
        let clean = segments
            .map { SpeechSegment(start: max(0, $0.start), end: min(audioSeconds, $0.end)) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        let speech = clean.reduce(0) { $0 + $1.duration }

        guard let first = clean.first, let last = clean.max(by: { $0.end < $1.end }),
              speech >= minSpeechSeconds
        else {
            return VADDecision(
                segments: clean, speechSeconds: speech, audioSeconds: audioSeconds,
                skip: true, trimRange: 0..<0)
        }

        let lower = Int(max(0, first.start - padSeconds) * sampleRate)
        let upper = Int(min(audioSeconds, last.end + padSeconds) * sampleRate)
        return VADDecision(
            segments: clean, speechSeconds: speech, audioSeconds: audioSeconds,
            skip: false, trimRange: max(0, lower)..<min(sampleCount, max(lower, upper)))
    }

    /// Used when VAD is disabled: keep everything.
    public static func passThrough(sampleCount: Int, sampleRate: Double) -> VADDecision {
        let seconds = Double(sampleCount) / sampleRate
        return VADDecision(
            segments: [SpeechSegment(start: 0, end: seconds)], speechSeconds: seconds,
            audioSeconds: seconds, skip: sampleCount == 0, trimRange: 0..<sampleCount)
    }
}

/// A simple energy-based detector. It is the fallback when the Silero model file
/// is missing; Silero is much better at telling speech from noise like typing.
public struct EnergyVAD: VoiceActivityDetector {
    public var name: String { "energy" }
    public var frameSeconds: Double = 0.03
    /// A frame counts as speech if it is this many dB above the noise floor...
    public var marginDB: Float = 12
    /// ...and above this absolute level.
    public var absoluteFloorDB: Float = -50
    /// Gaps shorter than this between speech frames are bridged.
    public var hangoverSeconds: Double = 0.2
    /// Segments shorter than this are dropped (clicks, bumps).
    public var minSegmentSeconds: Double = 0.12

    public init() {}

    public func speechSegments(in samples: [Float], sampleRate: Double) -> [SpeechSegment] {
        let frame = max(1, Int(frameSeconds * sampleRate))
        guard samples.count >= frame else { return [] }

        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            let rms = (sum / Float(frame)).squareRoot()
            levels.append(20 * log10(max(rms, 1e-7)))
            i += frame
        }

        // Noise floor: 10th percentile of frame levels.
        let sorted = levels.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let threshold = max(floor + marginDB, absoluteFloorDB)

        var segments: [SpeechSegment] = []
        var start: Int? = nil
        var lastSpeech = 0
        let hangoverFrames = Int(hangoverSeconds / frameSeconds)
        for (index, level) in levels.enumerated() {
            if level >= threshold {
                if start == nil { start = index }
                lastSpeech = index
            } else if let s = start, index - lastSpeech > hangoverFrames {
                segments.append(segment(s, lastSpeech, frame: frame, sampleRate: sampleRate))
                start = nil
            }
        }
        if let s = start {
            segments.append(segment(s, lastSpeech, frame: frame, sampleRate: sampleRate))
        }
        return segments.filter { $0.duration >= minSegmentSeconds }
    }

    private func segment(_ first: Int, _ last: Int, frame: Int, sampleRate: Double) -> SpeechSegment {
        SpeechSegment(
            start: Double(first * frame) / sampleRate,
            end: Double((last + 1) * frame) / sampleRate)
    }
}
