import Combine
import DictateCore
import Foundation

/// What the overlay is showing.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(DictationMode)
        case processing(DictationMode)
        /// Text was pasted. `detail` is a short note under the preview.
        case done(DictationMode, text: String, detail: String?)
        /// Something to tell the user (nothing heard, permission missing, error).
        case message(String, isError: Bool)
    }

    static let barCount = 24

    @Published var phase: Phase = .hidden
    /// Recent microphone levels, 0…1, oldest first.
    @Published var levels: [Float] = Array(repeating: 0, count: OverlayModel.barCount)

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }

    func push(rms: Float) {
        var l = levels
        LevelMeter.push(LevelMeter.normalized(rms: rms), into: &l, count: Self.barCount)
        levels = l
    }
}
