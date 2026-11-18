import Foundation

/// Keyboard events, already reduced to what the state machine needs.
/// The macOS event tap produces these; tests can feed them directly.
public enum HotkeyInput: Equatable, Sendable {
    /// A modifier key went down. `time` is in seconds (any monotonic clock).
    case modifierDown(ModifierKey, time: Double)
    case modifierUp(ModifierKey, time: Double)
    /// Any non-modifier key went down (Esc is reported separately).
    case otherKeyDown(time: Double)
    case escape(time: Double)
}

public enum CancelReason: String, Equatable, Sendable {
    /// Released before `minHoldSeconds`.
    case tooShort
    /// Another key was pressed while the hotkey was held (e.g. Right ⌘ + C).
    case chord
    /// Esc was pressed.
    case escape
}

/// What the app should do in response to an input.
public enum HotkeyAction: Equatable, Sendable {
    case startRecording(DictationMode)
    case stopRecording(DictationMode)
    case cancelRecording(DictationMode, CancelReason)
}

/// Turns modifier-key presses into start/stop/cancel actions for both modes.
///
/// Recording starts on key-down in every case, so the first syllable is not lost while
/// the press is being classified. If the press turns out to be a tap, a chord or a cancel,
/// the recording is discarded.
///
/// Hold behavior: down = start, up = stop. A press shorter than `minHoldSeconds` is
/// discarded. Pressing any other key during the hold cancels (so Right ⌘ + C still copies).
///
/// Toggle behavior: a short tap starts recording and the next press of the same key stops it.
/// A long press (longer than `tapMaxSeconds`) acts like hold.
///
/// While one mode is recording, the other mode's key is ignored.
public final class HotkeyStateMachine {
    public struct Settings: Equatable, Sendable {
        public var bindings: [DictationMode: HotkeyConfig]
        public var minHoldSeconds: Double
        public var tapMaxSeconds: Double

        public init(bindings: [DictationMode: HotkeyConfig], minHoldSeconds: Double, tapMaxSeconds: Double) {
            self.bindings = bindings
            self.minHoldSeconds = minHoldSeconds
            self.tapMaxSeconds = tapMaxSeconds
        }

        public init(config: AppConfig) {
            self.init(
                bindings: [.raw: config.rawHotkey, .clean: config.cleanHotkey],
                minHoldSeconds: config.minHoldSeconds,
                tapMaxSeconds: config.tapMaxSeconds)
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Key is down and recording has started; we don't yet know if it's a hold or a tap.
        case pressed(DictationMode, since: Double)
        /// Toggle mode: tapped once, recording continues after release.
        case latched(DictationMode)
        /// Recording was cancelled or stopped while the key is still down; wait for release.
        case waitingForRelease(ModifierKey)
    }

    public private(set) var state: State = .idle
    public var settings: Settings

    public init(settings: Settings) {
        self.settings = settings
    }

    /// True while a recording is in progress.
    public var isRecording: Bool {
        switch state {
        case .pressed, .latched: return true
        case .idle, .waitingForRelease: return false
        }
    }

    /// Call when recording ended for an outside reason (time limit, error). Returns to idle,
    /// or waits for the key to be released if it's still held.
    public func reset() {
        switch state {
        case .pressed(let mode, _):
            if let key = settings.bindings[mode]?.key { state = .waitingForRelease(key) } else { state = .idle }
        default:
            state = .idle
        }
    }

    private func mode(for key: ModifierKey) -> DictationMode? {
        settings.bindings.first(where: { $0.value.key == key })?.key
    }

    private func behavior(_ mode: DictationMode) -> HotkeyBehavior {
        settings.bindings[mode]?.behavior ?? .hold
    }

    private func key(_ mode: DictationMode) -> ModifierKey? {
        settings.bindings[mode]?.key
    }

    @discardableResult
    public func handle(_ input: HotkeyInput) -> HotkeyAction? {
        switch (state, input) {

        // Idle: a bound key starts recording.
        case (.idle, .modifierDown(let key, let t)):
            guard let mode = mode(for: key) else { return nil }
            state = .pressed(mode, since: t)
            return .startRecording(mode)

        // Pressed: decide what the press was.
        case (.pressed(let mode, let since), .modifierUp(let key, let t)) where key == self.key(mode):
            let held = t - since
            switch behavior(mode) {
            case .hold:
                state = .idle
                return held < settings.minHoldSeconds
                    ? .cancelRecording(mode, .tooShort)
                    : .stopRecording(mode)
            case .toggle:
                if held <= settings.tapMaxSeconds {
                    state = .latched(mode)  // tap: keep recording until the next press
                    return nil
                }
                state = .idle  // long press: behaves like hold
                return .stopRecording(mode)
            }

        case (.pressed(let mode, _), .otherKeyDown):
            state = .waitingForRelease(key(mode)!)
            return .cancelRecording(mode, .chord)

        case (.pressed(let mode, _), .escape):
            state = .waitingForRelease(key(mode)!)
            return .cancelRecording(mode, .escape)

        // Latched (toggle mode, recording after a tap).
        case (.latched(let mode), .modifierDown(let key, _)) where key == self.key(mode):
            state = .waitingForRelease(key)
            return .stopRecording(mode)

        case (.latched(let mode), .escape):
            state = .idle
            return .cancelRecording(mode, .escape)

        // Waiting for the key to come back up after a stop/cancel.
        case (.waitingForRelease(let waiting), .modifierUp(let key, _)) where key == waiting:
            state = .idle
            return nil

        // A key-down while waiting means the release event was missed (this can happen if
        // macOS briefly disabled the event tap). Treat it as a fresh press.
        case (.waitingForRelease, .modifierDown(let key, let t)):
            guard let mode = mode(for: key) else { return nil }
            state = .pressed(mode, since: t)
            return .startRecording(mode)

        default:
            return nil
        }
    }
}
