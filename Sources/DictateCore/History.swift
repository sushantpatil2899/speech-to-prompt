import Foundation

/// One dictation, as stored in history.jsonl (one JSON object per line).
public struct HistoryRecord: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var mode: DictationMode
    public var engine: String
    /// LLM used in clean mode (nil in raw mode or before stage 3).
    public var llmModel: String?
    public var rawText: String
    public var cleanedText: String?
    /// The text that was actually pasted / output.
    public var finalText: String
    /// True if clean mode fell back to the raw transcript.
    public var usedFallback: Bool
    /// Why something was skipped, discarded or fell back.
    public var note: String?
    public var audioSeconds: Double
    public var speechSeconds: Double
    /// Stage durations in milliseconds (see LatencyTimer).
    public var latencyMS: [String: Double]
    /// Bundle ID of the app that had focus.
    public var frontmostApp: String?
    /// Path of the saved WAV, if saveAudio is on.
    public var audioPath: String?

    public init(
        timestamp: Date = Date(), mode: DictationMode, engine: String, llmModel: String? = nil,
        rawText: String, cleanedText: String? = nil, finalText: String, usedFallback: Bool = false,
        note: String? = nil, audioSeconds: Double, speechSeconds: Double,
        latencyMS: [String: Double], frontmostApp: String? = nil, audioPath: String? = nil
    ) {
        self.timestamp = timestamp
        self.mode = mode
        self.engine = engine
        self.llmModel = llmModel
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.finalText = finalText
        self.usedFallback = usedFallback
        self.note = note
        self.audioSeconds = audioSeconds
        self.speechSeconds = speechSeconds
        self.latencyMS = latencyMS
        self.frontmostApp = frontmostApp
        self.audioPath = audioPath
    }
}

/// Appends records to a JSON Lines file. Thread-safe.
public final class HistoryLog {
    public let url: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(url: URL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func append(_ record: HistoryRecord) throws {
        var line = try encoder.encode(record)
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public static func readAll(from url: URL) throws -> [HistoryRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(HistoryRecord.self, from: Data(line.utf8))
        }
    }
}

/// Where the app keeps its files.
public struct AppPaths: Sendable {
    public var supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    /// ~/Library/Application Support/SpeechToPrompt
    public static var standard: AppPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AppPaths(supportDirectory: home
            .appendingPathComponent("Library/Application Support/SpeechToPrompt", isDirectory: true))
    }

    public var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public var historyFile: URL { supportDirectory.appendingPathComponent("history.jsonl") }
    public var modelsDirectory: URL { supportDirectory.appendingPathComponent("models", isDirectory: true) }
    public var recordingsDirectory: URL { supportDirectory.appendingPathComponent("recordings", isDirectory: true) }

    public func model(_ fileName: String) -> URL {
        // Absolute paths in config are used as-is.
        if fileName.hasPrefix("/") { return URL(fileURLWithPath: fileName) }
        return modelsDirectory.appendingPathComponent(fileName)
    }
}
