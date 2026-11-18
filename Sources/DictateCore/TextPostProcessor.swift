import Foundation

/// Light, engine-independent cleanup of a transcript before it is used.
/// It never rewrites words; that is the LLM's job in clean mode.
public enum TextPostProcessor {
    /// Phrases Whisper is known to produce on near-silent or noisy audio
    /// (they are common in its training data, e.g. video subtitles).
    public static let defaultPhantomPhrases: [String] = [
        "thank you",
        "thanks for watching",
        "thank you for watching",
        "thanks for watching and see you next time",
        "please subscribe",
        "subscribe to my channel",
        "you",
        "the end",
        "subtitles by the amara.org community",
    ]

    /// Collapses whitespace, strips leading/trailing space, and removes the bracketed
    /// non-speech tags Whisper sometimes emits ("[BLANK_AUDIO]", "(music)", "[typing]").
    public static func normalizeWhitespace(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(
            of: #"\[(?:[A-Z_ ]+|[a-z ]+)\]|\((?:music|applause|laughs?|laughter|silence|typing|noise|inaudible|blank audio)\)|♪+"#,
            with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercase, letters/digits/spaces only. Used for phantom-phrase matching.
    public static func comparable(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// True if the whole transcript is just a known hallucination phrase.
    public static func isPhantom(_ text: String, phrases: [String]) -> Bool {
        let c = comparable(text)
        if c.isEmpty { return true }
        return phrases.contains { comparable($0) == c }
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        /// Why the text was discarded, if it was.
        public var discardedReason: String?
    }

    /// Full post-processing: whitespace/tag cleanup, then the phantom check for short clips.
    public static func process(
        _ text: String, speechSeconds: Double, config: AppConfig
    ) -> Result {
        let cleaned = normalizeWhitespace(text)
        if cleaned.isEmpty {
            return Result(text: "", discardedReason: "empty transcript")
        }
        if speechSeconds <= config.phantomMaxSpeechSeconds,
           isPhantom(cleaned, phrases: config.phantomPhrases) {
            return Result(text: "", discardedReason: "phantom phrase \"\(cleaned)\" on \(String(format: "%.2f", speechSeconds)) s of speech")
        }
        return Result(text: cleaned, discardedReason: nil)
    }
}
