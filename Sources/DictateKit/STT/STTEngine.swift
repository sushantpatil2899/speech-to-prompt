import AVFoundation
import DictateCore

/// Extra information passed to the engine for one clip.
public struct STTContext: Sendable {
    /// Words and names to bias recognition towards (config `vocabulary`).
    public var vocabulary: [String]
    /// Free text to prime the engine with, e.g. recent chat messages (stage 4).
    public var priorText: String?

    public init(vocabulary: [String] = [], priorText: String? = nil) {
        self.vocabulary = vocabulary
        self.priorText = priorText
    }
}

public enum STTError: Error, CustomStringConvertible {
    case modelMissing(String)
    case loadFailed(String)
    case notPrepared
    case unsupportedLocale(String)
    case transcriptionFailed(String)

    public var description: String {
        switch self {
        case .modelMissing(let p): return "Model file not found: \(p). Run scripts/setup.sh."
        case .loadFailed(let s): return "Could not load the speech model: \(s)"
        case .notPrepared: return "The speech engine is not ready yet."
        case .unsupportedLocale(let l): return "This Mac's speech engine does not support locale \(l)."
        case .transcriptionFailed(let s): return "Transcription failed: \(s)"
        }
    }
}

/// A speech-to-text engine. Every engine receives 16 kHz mono Float32 samples
/// that already passed the VAD gate.
public protocol STTEngine: AnyObject {
    /// Short identifier stored in the history log and eval reports.
    var name: String { get }
    /// Load models / install assets and warm up. Safe to call more than once.
    func prepare() async throws
    /// Transcribe a complete clip.
    func transcribe(_ samples: [Float], context: STTContext) async throws -> String
    /// Engines that can transcribe while you speak return a stream; others return nil.
    /// Synchronous so the stream can be attached to the recorder before recording starts.
    func makeStream(context: STTContext) throws -> STTStream?
}

extension STTEngine {
    public func makeStream(context: STTContext) throws -> STTStream? { nil }
}

/// A live transcription in progress.
public protocol STTStream: AnyObject {
    /// Feed a 16 kHz mono Float32 chunk. Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio; wait for the final text.
    func finish() async throws -> String
    /// Discard the stream.
    func cancel() async
}

/// Builds the engine described by the config.
public enum EngineFactory {
    public static func make(_ config: EngineConfig, paths: AppPaths) -> STTEngine {
        switch config.kind {
        case .whisper:
            return WhisperCppEngine(
                modelURL: paths.model(config.whisperModel),
                beamSize: config.whisperBeamSize,
                temperatureFallback: config.whisperTemperatureFallback,
                threads: config.whisperThreads)
        case .apple:
            return AppleSpeechEngine(locale: Locale(identifier: config.locale), kind: .transcriber)
        case .appleDictation:
            return AppleSpeechEngine(locale: Locale(identifier: config.locale), kind: .dictation)
        }
    }

    /// The VAD to use: Silero if its model is installed, otherwise the energy detector.
    public static func makeVAD(_ config: VADConfig, paths: AppPaths) -> VoiceActivityDetector {
        let url = paths.model(config.sileroModel)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return try SileroVAD(modelURL: url, threshold: Float(config.threshold))
            } catch {
                Log.stt.error("Silero VAD failed to load (\(String(describing: error), privacy: .public)); using energy VAD")
            }
        } else {
            Log.stt.notice("Silero VAD model not found at \(url.path, privacy: .public); using energy VAD")
        }
        return EnergyVAD()
    }
}
