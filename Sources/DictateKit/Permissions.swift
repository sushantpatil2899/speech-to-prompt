import AppKit
import ApplicationServices
import AVFoundation

/// The macOS privacy permissions the app uses. See docs/PERMISSIONS.md.
public enum Permission: String, CaseIterable, Sendable {
    case microphone
    case inputMonitoring
    case accessibility

    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    /// What the app uses it for.
    public var purpose: String {
        switch self {
        case .microphone: return "record your voice"
        case .inputMonitoring: return "detect the push-to-talk keys"
        case .accessibility: return "paste with ⌘V (from stage 2)"
        }
    }

    public var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    /// Triggers the system prompt where macOS offers one.
    public func request() async {
        switch self {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    /// Opens the matching page in System Settings → Privacy & Security.
    public func openSettings() {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
