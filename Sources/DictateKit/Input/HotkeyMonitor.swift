import ApplicationServices
import CoreGraphics
import DictateCore
import Foundation

/// Watches the keyboard with a listen-only CGEventTap and reports modifier presses.
///
/// Listen-only means it never blocks or changes keystrokes. It needs the
/// Input Monitoring permission (not Accessibility).
public final class HotkeyMonitor {
    /// Called on the main thread.
    public var onInput: ((HotkeyInput) -> Void)?
    /// Called on the main thread for every non-repeat key-down (used later to detect typing after a paste).
    public var onAnyKeyDown: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var down: Set<ModifierKey> = []

    public init() {}

    deinit { stop() }

    public static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt (first time only) and adds the app to the Input Monitoring list.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    public var isRunning: Bool { tap != nil }

    /// Returns false if the tap couldn't be created (usually: permission not granted yet).
    @discardableResult
    public func start() -> Bool {
        if tap != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.hotkey.error("Could not create event tap (Input Monitoring permission missing?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.hotkey.info("Event tap started")
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        down.removeAll()
    }

    // Device-dependent modifier bits (NX_DEVICE*KEYMASK in IOKit's IOLLEvent.h).
    // They tell left and right keys apart.
    private static func deviceMask(_ key: ModifierKey) -> UInt64 {
        switch key {
        case .leftControl: return 0x0000_0001
        case .leftShift: return 0x0000_0002
        case .rightShift: return 0x0000_0004
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .leftOption: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        case .rightControl: return 0x0000_2000
        case .function: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let now = LatencyTimer.now()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables taps that are slow to respond; turn it back on.
            Log.hotkey.notice("Event tap was disabled by the system; re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard let key = ModifierKey(keyCode: code) else { return }
            let isDown = event.flags.rawValue & Self.deviceMask(key) != 0
            if isDown, !down.contains(key) {
                down.insert(key)
                onInput?(.modifierDown(key, time: now))
            } else if !isDown, down.contains(key) {
                down.remove(key)
                onInput?(.modifierUp(key, time: now))
            }

        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            onAnyKeyDown?()
            onInput?(code == 53 ? .escape(time: now) : .otherKeyDown(time: now))

        default:
            break
        }
    }
}
