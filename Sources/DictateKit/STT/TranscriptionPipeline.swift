import Foundation
import DictateCore

/// What one clip produced.
public struct PipelineResult: Sendable {
    /// Text after cleanup (empty if the clip was skipped or discarded).
    public var text: String
    /// Text exactly as the engine returned it.
    public var engineText: String
    public var decision: VADDecision
    /// Why nothing was produced, if so.
    public var note: String?
    public var skipped: Bool { text.isEmpty }
}

/// VAD gate → speech engine → text cleanup. Shared by the app and dictate-cli,
/// so the eval measures exactly what the app does.
public final class TranscriptionPipeline {
    public let engine: STTEngine
    public let vad: VoiceActivityDetector
    public let config: AppConfig

    public init(engine: STTEngine, vad: VoiceActivityDetector, config: AppConfig) {
        self.engine = engine
        self.vad = vad
        self.config = config
    }

    public var context: STTContext { STTContext(vocabulary: config.vocabulary) }

    /// - Parameters:
    ///   - samples: the full recording, 16 kHz mono.
    ///   - stream: a live stream that already received the same audio (Apple engine), or nil.
    ///   - timer: gets the "vadDone" and "sttDone" marks.
    public func run(samples: [Float], stream: STTStream?, timer: inout LatencyTimer) async throws -> PipelineResult {
        let decision: VADDecision
        if config.vad.enabled {
            let segments = vad.speechSegments(in: samples, sampleRate: PCM.sampleRate)
            decision = VADGate.decide(
                segments: segments, sampleCount: samples.count, sampleRate: PCM.sampleRate,
                minSpeechSeconds: config.vad.minSpeechSeconds, padSeconds: config.vad.padSeconds)
        } else {
            decision = VADGate.passThrough(sampleCount: samples.count, sampleRate: PCM.sampleRate)
        }
        timer.mark("vadDone")

        if decision.skip {
            if let stream { await stream.cancel() }
            timer.mark("sttDone")
            let note = String(format: "skipped: %.2f s of speech detected by %@ (minimum %.2f s)",
                              decision.speechSeconds, vad.name, config.vad.minSpeechSeconds)
            return PipelineResult(text: "", engineText: "", decision: decision, note: note)
        }

        let engineText: String
        if let stream {
            engineText = try await stream.finish()
        } else {
            engineText = try await engine.transcribe(decision.trimmed(samples), context: context)
        }
        timer.mark("sttDone")

        let processed = TextPostProcessor.process(engineText, speechSeconds: decision.speechSeconds, config: config)
        return PipelineResult(
            text: processed.text, engineText: engineText, decision: decision, note: processed.discardedReason)
    }
}
