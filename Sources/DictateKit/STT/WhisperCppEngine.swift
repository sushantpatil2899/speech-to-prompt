import Foundation
import DictateCore
import whisper

/// Whisper via whisper.cpp (Metal). The model is loaded once and kept in memory.
///
/// Decoding settings chosen against hallucination:
/// - language forced to "en" (no auto-detect)
/// - no_context = true  (= condition_on_previous_text=False in openai-whisper)
/// - suppress_blank and suppress_nst (non-speech tokens)
/// - temperature 0, with whisper's standard fallback unless disabled in config
/// The VAD gate runs before this, so near-silent clips never reach the model.
public final class WhisperCppEngine: STTEngine {
    public let modelURL: URL
    public let beamSize: Int
    public let temperatureFallback: Bool
    private let threads: Int32
    private var ctx: OpaquePointer?
    /// whisper.cpp contexts are not thread-safe; every call goes through this queue.
    private let queue = DispatchQueue(label: "local.SpeechToPrompt.whisper", qos: .userInitiated)

    /// Highest per-segment no-speech probability of the last transcription (for diagnostics).
    public private(set) var lastMaxNoSpeechProb: Float = 0

    public init(modelURL: URL, beamSize: Int = 0, temperatureFallback: Bool = true, threads: Int = 0) {
        self.modelURL = modelURL
        self.beamSize = beamSize
        self.temperatureFallback = temperatureFallback
        self.threads = Int32(threads > 0 ? threads : 4)
        WhisperLogging.install()
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    public var name: String {
        var n = "whisper.cpp/" + modelURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        if beamSize > 1 { n += "/beam\(beamSize)" }
        if !temperatureFallback { n += "/nofallback" }
        return n
    }

    public func prepare() async throws {
        try await onQueue { () throws -> Void in
            if self.ctx != nil { return }
            let path = self.modelURL.path
            guard FileManager.default.fileExists(atPath: path) else { throw STTError.modelMissing(path) }
            var cparams = whisper_context_default_params()
            cparams.use_gpu = true
            cparams.flash_attn = true
            guard let context = whisper_init_from_file_with_params(path, cparams) else {
                throw STTError.loadFailed(path)
            }
            self.ctx = context
            // Warm-up so the first real dictation doesn't pay for Metal pipeline setup.
            _ = try self.runFull(samples: [Float](repeating: 0, count: 16000), prompt: nil)
            Log.stt.info("whisper.cpp model loaded: \(path, privacy: .public)")
        }
    }

    public func transcribe(_ samples: [Float], context: STTContext) async throws -> String {
        let prompt = Self.initialPrompt(for: context)
        return try await onQueue { try self.runFull(samples: samples, prompt: prompt) }
    }

    /// Whisper's initial prompt: vocabulary first, then any prior text, kept short.
    /// (whisper.cpp uses at most ~224 prompt tokens; long prompts also raise the risk
    /// of the model repeating the prompt back.)
    static func initialPrompt(for context: STTContext) -> String? {
        var parts: [String] = []
        if !context.vocabulary.isEmpty {
            parts.append("Glossary: " + context.vocabulary.joined(separator: ", ") + ".")
        }
        if let prior = context.priorText?.trimmingCharacters(in: .whitespacesAndNewlines), !prior.isEmpty {
            parts.append(String(prior.suffix(600)))
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : String(joined.prefix(800))
    }

    private func runFull(samples: [Float], prompt: String?) throws -> String {
        guard let ctx else { throw STTError.notPrepared }
        guard !samples.isEmpty else { return "" }

        let strategy = beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY
        var p = whisper_full_default_params(strategy)
        p.n_threads = threads
        p.translate = false
        p.no_context = true
        p.no_timestamps = true
        p.single_segment = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.temperature = 0
        if !temperatureFallback { p.temperature_inc = 0 }
        if beamSize > 1 { p.beam_search.beam_size = Int32(beamSize) }

        let status: Int32 = "en".withCString { lang in
            p.language = lang
            return withOptionalCString(prompt) { promptPtr in
                p.initial_prompt = promptPtr
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
                }
            }
        }
        guard status == 0 else { throw STTError.transcriptionFailed("whisper_full returned \(status)") }

        var text = ""
        var maxNoSpeech: Float = 0
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cstr)
            }
            maxNoSpeech = max(maxNoSpeech, whisper_full_get_segment_no_speech_prob(ctx, i))
        }
        lastMaxNoSpeechProb = maxNoSpeech
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Silero VAD from whisper.cpp. Used as the shared gate for every engine.
public final class SileroVAD: VoiceActivityDetector {
    private let vctx: OpaquePointer
    private let lock = NSLock()
    public let threshold: Float
    public var name: String { "silero" }

    public init(modelURL: URL, threshold: Float) throws {
        WhisperLogging.install()
        var cparams = whisper_vad_default_context_params()
        cparams.n_threads = 2
        cparams.use_gpu = false
        guard let v = whisper_vad_init_from_file_with_params(modelURL.path, cparams) else {
            throw STTError.loadFailed(modelURL.path)
        }
        vctx = v
        self.threshold = threshold
    }

    deinit { whisper_vad_free(vctx) }

    public func speechSegments(in samples: [Float], sampleRate: Double) -> [SpeechSegment] {
        // Silero needs at least one 32 ms window.
        guard samples.count >= 512 else { return [] }
        lock.lock(); defer { lock.unlock() }
        var params = whisper_vad_default_params()
        params.threshold = threshold
        params.speech_pad_ms = 0  // VADGate adds its own padding
        let segs = samples.withUnsafeBufferPointer { buf in
            whisper_vad_segments_from_samples(vctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard let segs else { return [] }
        defer { whisper_vad_free_segments(segs) }
        let n = whisper_vad_segments_n_segments(segs)
        // whisper.cpp reports VAD segment times in centiseconds.
        return (0..<n).map { i in
            SpeechSegment(
                start: Double(whisper_vad_segments_get_segment_t0(segs, i)) / 100,
                end: Double(whisper_vad_segments_get_segment_t1(segs, i)) / 100)
        }
    }
}

/// Routes whisper.cpp / ggml log output: errors go to the unified log, the rest is dropped
/// (otherwise every call prints pages of model info to stderr).
enum WhisperLogging {
    private static var installed = false
    private static let lock = NSLock()

    static func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        if ProcessInfo.processInfo.environment["STP_WHISPER_VERBOSE"] != nil { return }
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            Log.stt.error("whisper.cpp: \(String(cString: text), privacy: .public)")
        }, nil)
    }
}

func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    if let string { return string.withCString { body($0) } }
    return body(nil)
}
