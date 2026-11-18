import AppKit
import ApplicationServices

/// Decides whether the overlay's Cleaned/Raw toggle may replace text in place (⌘Z, then paste
/// the other version) or should only copy it to the clipboard.
///
/// In-place replacement is allowed only if, since the paste:
/// - the same app is still frontmost,
/// - the same UI element still has keyboard focus (when the app exposes it),
/// - you haven't typed, and haven't clicked anywhere except the overlay.
@MainActor
public final class SwapGuard {
    private struct Target {
        var pid: pid_t
        var element: AXUIElement?
    }

    private var target: Target?
    private var interacted = false

    public init() {}

    /// Call right after pasting.
    public func arm() {
        guard let app = NSWorkspace.shared.frontmostApplication else { target = nil; return }
        target = Target(pid: app.processIdentifier, element: Self.focusedElement())
        interacted = false
    }

    public func disarm() {
        target = nil
    }

    /// A real (not synthetic) key press happened.
    public func noteKeyDown() {
        if target != nil { interacted = true }
    }

    /// A mouse button went down. `cgPoint` is in global CoreGraphics coordinates (origin at the
    /// top-left of the main display). Clicks inside `ignoring` (Cocoa screen coordinates, e.g.
    /// the overlay's frame) don't count.
    public func noteMouseDown(cgPoint: CGPoint, ignoring rect: NSRect?) {
        guard target != nil else { return }
        if let rect, let primary = NSScreen.screens.first {
            let cocoa = NSPoint(x: cgPoint.x, y: primary.frame.height - cgPoint.y)
            if rect.contains(cocoa) { return }
        }
        interacted = true
    }

    /// Why an in-place swap isn't safe, or nil if it is.
    public func blockReason() -> String? {
        guard let target else { return "nothing to replace" }
        if interacted { return "you typed or clicked since the paste" }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            return "a different app is in front"
        }
        if let before = target.element {
            guard let now = Self.focusedElement(), CFEqual(before, now) else {
                return "the focused field changed"
            }
        }
        return nil
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
