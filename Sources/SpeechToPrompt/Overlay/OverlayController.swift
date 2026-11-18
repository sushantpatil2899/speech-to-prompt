import AppKit
import DictateCore
import SwiftUI

/// A panel that never becomes key or main, so showing it (and later clicking it)
/// never takes focus away from the text field you're dictating into.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows and hides the overlay in the top-right corner of the screen you're working on.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    var enabled = true
    var doneSeconds: Double = 1.5

    private var panel: OverlayPanel?
    /// Bumped on every state change, so stale hide timers do nothing.
    private var generation = 0

    // MARK: States

    func showListening(_ mode: DictationMode) {
        model.resetLevels()
        set(.listening(mode))
    }

    /// Call from the main thread with the RMS of each audio chunk.
    func pushLevel(_ rms: Float) {
        guard case .listening = model.phase else { return }
        model.push(rms: rms)
    }

    func showProcessing(_ mode: DictationMode) {
        set(.processing(mode))
    }

    func showDone(_ mode: DictationMode, text: String, detail: String? = nil) {
        set(.done(mode, text: text, detail: detail))
        hide(after: doneSeconds)
    }

    func showMessage(_ text: String, isError: Bool, seconds: Double = 2.5) {
        set(.message(text, isError: isError))
        hide(after: seconds)
    }

    func hide(after seconds: Double = 0) {
        let gen = generation
        Task { @MainActor [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard let self, self.generation == gen else { return }
            self.fadeOut(generation: gen)
        }
    }

    // MARK: Panel

    private func set(_ phase: OverlayModel.Phase) {
        generation += 1
        guard enabled else { return }
        model.phase = phase
        present()
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()  // shows without activating this app
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut(generation gen: Int) {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.generation == gen else { return }
            panel.orderOut(nil)
            self.model.phase = .hidden
        }
    }

    private func makePanel() -> OverlayPanel {
        let size = Self.panelSize
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false        // SwiftUI draws the shadow
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true // no buttons until stage 3's raw/clean toggle
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }

    private static var panelSize: CGSize {
        CGSize(width: OverlayView.cardSize.width + 20, height: OverlayView.cardSize.height + 20)
    }

    /// Top-right of the screen the mouse is on, just below the menu bar.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = Self.panelSize
        let origin = NSPoint(x: visible.maxX - size.width - 6, y: visible.maxY - size.height - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
