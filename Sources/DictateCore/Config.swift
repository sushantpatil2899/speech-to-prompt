import Foundation

/// The two dictation modes, each bound to its own hotkey.
public enum DictationMode: String, Codable, CaseIterable, Sendable {
    /// Transcribe and paste. No LLM.
    case raw
    /// Transcribe, rewrite with the local LLM, then paste.
    case clean
}

/// How a hotkey starts and stops recording.
public enum HotkeyBehavior: String, Codable, Sendable {
    /// Record while the key is held; release to stop.
    case hold
    /// Tap once to start, tap again to stop. A long press still works like `hold`.
    case toggle
}

/// Modifier keys that can be used on their own as a push-to-talk key.
/// Raw values are the names used in config.json.
public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case rightOption, leftOption
    case rightCommand, leftCommand
    case rightControl, leftControl
    case rightShift, leftShift
    case function

    /// macOS virtual key code (kVK_* in Carbon's Events.h).
    public var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .rightControl: return 62
        case .leftControl: return 59
        case .rightShift: return 60
        case .leftShift: return 56
        case .function: return 63
        }
    }

    public init?(keyCode: UInt16) {
        guard let match = ModifierKey.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = match
    }

    public var displayName: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .leftOption: return "Left ⌥"
        case .rightCommand: return "Right ⌘"
        case .leftCommand: return "Left ⌘"
        case .rightControl: return "Right ⌃"
        case .leftControl: return "Left ⌃"
        case .rightShift: return "Right ⇧"
        case .leftShift: return "Left ⇧"
        case .function: return "fn"
        }
    }
}

public struct HotkeyConfig: Codable, Equatable, Sendable {
    public var key: ModifierKey
    public var behavior: HotkeyBehavior

    public init(key: ModifierKey, behavior: HotkeyBehavior) {
        self.key = key
        self.behavior = behavior
    }
}

/// Which speech-to-text engine to use.
public enum EngineKind: String, Codable, CaseIterable, Sendable {
    /// whisper.cpp running Whisper (large-v3-turbo by default) on Metal.
    case whisper
    /// Apple SpeechAnalyzer + SpeechTranscriber (macOS 26, on-device).
    case apple
    /// Apple SpeechAnalyzer + DictationTranscriber (keyboard-dictation model).
    case appleDictation = "apple-dictation"

    public var displayName: String {
        switch self {
        case .whisper: return "Whisper (whisper.cpp)"
        case .apple: return "Apple SpeechTranscriber"
        case .appleDictation: return "Apple DictationTranscriber"
        }
    }
}

public struct EngineConfig: Codable, Equatable, Sendable {
    public var kind: EngineKind = .whisper
    /// Locale for the Apple engines. Whisper is always forced to English.
    public var locale: String = "en-IN"
    /// File name inside the models directory.
    public var whisperModel: String = "ggml-large-v3-turbo.bin"
    /// 0 = greedy decoding; >1 = beam search with that beam size.
    public var whisperBeamSize: Int = 0
    /// Whisper's temperature fallback (retry at a higher temperature when decoding looks bad).
    public var whisperTemperatureFallback: Bool = true
    /// 0 = choose automatically.
    public var whisperThreads: Int = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineConfig()
        kind = try c.decodeIfPresent(EngineKind.self, forKey: .kind) ?? d.kind
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? d.locale
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        whisperBeamSize = try c.decodeIfPresent(Int.self, forKey: .whisperBeamSize) ?? d.whisperBeamSize
        whisperTemperatureFallback = try c.decodeIfPresent(Bool.self, forKey: .whisperTemperatureFallback) ?? d.whisperTemperatureFallback
        whisperThreads = try c.decodeIfPresent(Int.self, forKey: .whisperThreads) ?? d.whisperThreads
    }
}

public struct VADConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    /// Clips with less detected speech than this are skipped (nothing is transcribed or pasted).
    public var minSpeechSeconds: Double = 0.3
    /// Silero speech-probability threshold.
    public var threshold: Double = 0.5
    /// Audio kept before the first and after the last speech segment when trimming.
    public var padSeconds: Double = 0.25
    /// File name inside the models directory. If it is missing, an energy-based VAD is used.
    public var sileroModel: String = "ggml-silero-v6.2.0.bin"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VADConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        minSpeechSeconds = try c.decodeIfPresent(Double.self, forKey: .minSpeechSeconds) ?? d.minSpeechSeconds
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
        padSeconds = try c.decodeIfPresent(Double.self, forKey: .padSeconds) ?? d.padSeconds
        sileroModel = try c.decodeIfPresent(String.self, forKey: .sileroModel) ?? d.sileroModel
    }
}

/// Everything in ~/Library/Application Support/SpeechToPrompt/config.json.
/// Every field is optional in the file; missing fields take the defaults below.
public struct AppConfig: Codable, Equatable, Sendable {
    public var rawHotkey = HotkeyConfig(key: .rightOption, behavior: .hold)
    public var cleanHotkey = HotkeyConfig(key: .rightCommand, behavior: .hold)
    /// In hold mode, presses shorter than this are treated as accidental taps and discarded.
    public var minHoldSeconds: Double = 0.2
    /// In toggle mode, a press shorter than this is a tap (start/stop); longer acts like hold.
    public var tapMaxSeconds: Double = 0.35
    /// Recording stops automatically after this long.
    public var maxRecordingSeconds: Double = 120
    public var engine = EngineConfig()
    public var vad = VADConfig()
    /// Words and names you use often (project names, people, jargon). Passed to Whisper as its
    /// initial prompt and to Apple's engine as contextual strings. Helps with accents.
    public var vocabulary: [String] = []
    /// Very short clips whose whole transcript is one of these are treated as hallucinations.
    public var phantomPhrases: [String] = TextPostProcessor.defaultPhantomPhrases
    /// Clips shorter than this (seconds of speech) are checked against `phantomPhrases`.
    public var phantomMaxSpeechSeconds: Double = 1.5
    /// Save each recording as a WAV next to the history log (for building eval clips).
    public var saveAudio: Bool = false
    /// Append one JSON line per dictation to history.jsonl.
    public var writeHistory: Bool = true

    public init() {}

    public func hotkey(for mode: DictationMode) -> HotkeyConfig {
        mode == .raw ? rawHotkey : cleanHotkey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        rawHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .rawHotkey) ?? d.rawHotkey
        cleanHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .cleanHotkey) ?? d.cleanHotkey
        minHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .minHoldSeconds) ?? d.minHoldSeconds
        tapMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .tapMaxSeconds) ?? d.tapMaxSeconds
        maxRecordingSeconds = try c.decodeIfPresent(Double.self, forKey: .maxRecordingSeconds) ?? d.maxRecordingSeconds
        engine = try c.decodeIfPresent(EngineConfig.self, forKey: .engine) ?? d.engine
        vad = try c.decodeIfPresent(VADConfig.self, forKey: .vad) ?? d.vad
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        phantomPhrases = try c.decodeIfPresent([String].self, forKey: .phantomPhrases) ?? d.phantomPhrases
        phantomMaxSpeechSeconds = try c.decodeIfPresent(Double.self, forKey: .phantomMaxSpeechSeconds) ?? d.phantomMaxSpeechSeconds
        saveAudio = try c.decodeIfPresent(Bool.self, forKey: .saveAudio) ?? d.saveAudio
        writeHistory = try c.decodeIfPresent(Bool.self, forKey: .writeHistory) ?? d.writeHistory
    }

    /// Problems that make the config unusable.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if rawHotkey.key == cleanHotkey.key {
            errors.append("rawHotkey and cleanHotkey use the same key (\(rawHotkey.key.rawValue)).")
        }
        if engine.whisperBeamSize < 0 { errors.append("engine.whisperBeamSize must be >= 0.") }
        if maxRecordingSeconds <= 0 { errors.append("maxRecordingSeconds must be > 0.") }
        if vad.minSpeechSeconds < 0 { errors.append("vad.minSpeechSeconds must be >= 0.") }
        return errors
    }

    // MARK: Loading and saving

    public static func load(from url: URL) throws -> AppConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// Loads the config, or writes the defaults if the file doesn't exist yet.
    public static func loadOrCreate(at url: URL) throws -> AppConfig {
        if FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }
        let config = AppConfig()
        try config.save(to: url)
        return config
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
