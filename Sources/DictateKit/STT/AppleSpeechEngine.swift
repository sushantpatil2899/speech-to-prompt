import AVFoundation
import DictateCore
import Speech

/// Apple's on-device speech recognition (macOS 26 SpeechAnalyzer).
///
/// Two modules are available:
/// - `.transcriber`: SpeechTranscriber, the new general-purpose model.
/// - `.dictation`: DictationTranscriber, the model behind keyboard dictation (adds punctuation).
///
/// It supports streaming: audio is fed while you speak, so on key release only the
/// final pass remains.
public final class AppleSpeechEngine: STTEngine {
    public enum Kind: Sendable { case transcriber, dictation }

    public let requestedLocale: Locale
    public let kind: Kind
    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?

    public init(locale: Locale, kind: Kind) {
        self.requestedLocale = locale
        self.kind = kind
    }

    public var name: String {
        let id = (locale ?? requestedLocale).identifier(.bcp47)
        return (kind == .transcriber ? "apple-speech/" : "apple-dictation/") + id
    }

    public func prepare() async throws {
        if locale != nil { return }
        let resolved: Locale?
        switch kind {
        case .transcriber: resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        case .dictation: resolved = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
        }
        guard let resolved else { throw STTError.unsupportedLocale(requestedLocale.identifier) }

        let module: any SpeechModule = Self.makeModule(kind: kind, locale: resolved).module
        // Downloads the on-device model for this locale the first time (from Apple).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.stt.notice("Installing Apple speech assets for \(resolved.identifier, privacy: .public)…")
            try await request.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        locale = resolved
        Log.stt.info("Apple engine ready: \(self.name, privacy: .public), format \(String(describing: self.analyzerFormat), privacy: .public)")
    }

    public func transcribe(_ samples: [Float], context: STTContext) async throws -> String {
        guard let session = try makeSession(context: context) else { throw STTError.notPrepared }
        if let buffer = PCM.buffer(from: samples) { session.append(buffer) }
        return try await session.finish()
    }

    public func makeStream(context: STTContext) throws -> STTStream? {
        try makeSession(context: context)
    }

    public func makeSession(context: STTContext) throws -> AppleSpeechSession? {
        guard let locale else { return nil }
        return try AppleSpeechSession(kind: kind, locale: locale, analyzerFormat: analyzerFormat, context: context)
    }

    // MARK: Module construction

    struct Module {
        let module: any SpeechModule
        /// Collects the final text from the module's results.
        let collect: () async throws -> String
    }

    static func makeModule(kind: Kind, locale: Locale) -> Module {
        switch kind {
        case .transcriber:
            let t = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            return Module(module: t) {
                var parts: [String] = []
                for try await result in t.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
                return parts.joined(separator: " ")
            }
        case .dictation:
            let d = DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [], attributeOptions: [])
            return Module(module: d) {
                var parts: [String] = []
                for try await result in d.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
                return parts.joined(separator: " ")
            }
        }
    }

    /// Locales the engines support on this Mac, and which are already installed.
    public static func localeReport() async -> String {
        func ids(_ ls: [Locale]) -> String { ls.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ") }
        let st = await SpeechTranscriber.supportedLocales
        let si = await SpeechTranscriber.installedLocales
        let dt = await DictationTranscriber.supportedLocales
        let di = await DictationTranscriber.installedLocales
        return """
        SpeechTranscriber supported: \(ids(st))
        SpeechTranscriber installed: \(ids(si))
        DictationTranscriber supported: \(ids(dt))
        DictationTranscriber installed: \(ids(di))
        """
    }
}

/// One analysis run. Audio can be appended before the analyzer has finished starting;
/// it is buffered in the input stream.
public final class AppleSpeechSession: STTStream {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: StreamingConverter?
    private let startTask: Task<Void, Error>
    private let collector: Task<String, Error>

    init(kind: AppleSpeechEngine.Kind, locale: Locale, analyzerFormat: AVAudioFormat?, context: STTContext) throws {
        let module = AppleSpeechEngine.makeModule(kind: kind, locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module.module])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        self.input = continuation
        if let analyzerFormat, analyzerFormat != PCM.format {
            converter = StreamingConverter(from: PCM.format, to: analyzerFormat)
        } else {
            converter = nil
        }
        let collect = module.collect
        collector = Task { try await collect() }

        let vocabulary = context.vocabulary
        startTask = Task {
            if !vocabulary.isEmpty {
                var analysisContext = AnalysisContext()
                analysisContext.contextualStrings = [.general: vocabulary]
                try await analyzer.setContext(analysisContext)
            }
            try await analyzer.start(inputSequence: stream)
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        let converted: AVAudioPCMBuffer?
        if let converter { converted = converter.convert(buffer) } else { converted = buffer }
        guard let converted, converted.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    public func finish() async throws -> String {
        input.finish()
        try await startTask.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    public func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        collector.cancel()
    }
}
