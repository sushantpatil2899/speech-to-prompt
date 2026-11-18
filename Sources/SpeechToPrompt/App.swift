import AppKit
import DictateKit

/// Menu bar app (LSUIElement: no Dock icon, no main window).
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var shared: AppDelegate?

    private let controller = DictationController()
    private var menu: StatusMenu?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenu(controller: controller)
        self.menu = menu
        controller.onStatusChange = { [weak menu] status in
            MainActor.assumeIsolated { menu?.update(status) }
        }
        controller.start()
        Log.app.info("SpeechToPrompt started")
    }
}
