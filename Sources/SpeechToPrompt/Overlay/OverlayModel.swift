import Combine
import DictateCore
import Foundation

/// What the overlay is showing.
@MainActor
final class OverlayModel: ObservableObject {
    enum Version: Equatable { case cleaned, raw }

    /// Clean mode result, with both versions for the toggle.
    struct CleanOutcome: Equatable {
        var raw: String
        /// nil if the LLM produced nothing usable (not running, timed out, empty).
        var cleaned: String?
        /// The version currently in the text field.
        var showing: Version
        /// True if the guardrails rejected the cleaned text (raw was pasted instead).
        var cleanedRejected: Bool
        /// Second line of the card: what happened.
        var detail: String

        var currentText: String { showing == .cleaned ? (cleaned ?? raw) : raw }
    }

    enum Phase: Equatable {
        case hidden
        case listening(DictationMode)
        case processing(DictationMode)
        /// Clean mode, waiting for the LLM.
        case rewriting
        /// Raw mode: text was pasted. `detail` is a short note under the preview.
        case done(DictationMode, text: String, detail: String?)
        /// Clean mode: pasted, with the Cleaned / Raw toggle.
        case cleanDone(CleanOutcome)
        /// Something to tell the user (nothing heard, permission missing, error).
        case message(String, isError: Bool)
    }

    static let barCount = 30

    @Published var phase: Phase = .hidden
    /// Recent microphone levels, 0…1, oldest first.
    @Published var levels: [Float] = Array(repeating: 0, count: OverlayModel.barCount)

    /// Called when the user clicks Clean or Raw on the card.
    var onSelectVersion: ((Version) -> Void)?

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }

    func push(rms: Float) {
        var l = levels
        LevelMeter.push(LevelMeter.normalized(rms: rms), into: &l, count: Self.barCount)
        levels = l
    }
}
