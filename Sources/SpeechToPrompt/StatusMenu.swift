import AppKit
import DictateCore
import DictateKit
import ServiceManagement

/// The menu bar icon and its menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController
    private let menu = NSMenu()

    init(controller: DictationController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        item.menu = menu
        update(controller.status)
    }

    func update(_ status: AppStatus) {
        let symbol: String
        switch status {
        case .loading: symbol = "hourglass"
        case .ready: symbol = controller.hotkeysActive ? "mic" : "mic.slash"
        case .recording: symbol = "mic.fill"
        case .processing: symbol = "waveform"
        case .error: symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SpeechToPrompt")
        image?.isTemplate = true
        item.button?.image = image
        if case .recording = status {
            item.button?.contentTintColor = .systemRed
        } else {
            item.button?.contentTintColor = nil
        }
    }

    // Rebuilt every time the menu opens so permissions and status are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = controller.config

        menu.addItem(disabled(statusLine()))
        menu.addItem(disabled("Raw: \(describe(config.rawHotkey))   ·   Clean: \(describe(config.cleanHotkey))"))
        if let problem = controller.configProblem { menu.addItem(disabled("⚠︎ \(problem)")) }
        if !controller.hotkeysActive {
            menu.addItem(disabled("⚠︎ Hotkeys inactive: grant Input Monitoring"))
        }

        if let last = controller.lastTranscript {
            let shown = last.count > 60 ? String(last.prefix(60)) + "…" : last
            menu.addItem(action("Copy last: “\(shown)”", #selector(copyLast)))
        }

        menu.addItem(.separator())

        let engines = NSMenu()
        for kind in EngineKind.allCases {
            var title = kind.displayName
            if kind != .whisper { title += " (\(config.engine.locale))" }
            let entry = action(title, #selector(chooseEngine(_:)))
            entry.representedObject = kind.rawValue
            entry.state = kind == config.engine.kind ? .on : .off
            engines.addItem(entry)
        }
        menu.addItem(submenu("Speech Engine", engines))

        let perms = NSMenu()
        for p in Permission.allCases {
            let entry = action("\(p.isGranted ? "✓" : "✗")  \(p.displayName): \(p.purpose)", #selector(openPermission(_:)))
            entry.representedObject = p.rawValue
            perms.addItem(entry)
        }
        menu.addItem(submenu("Permissions", perms))

        menu.addItem(.separator())
        menu.addItem(action("Open Config File", #selector(openConfig)))
        menu.addItem(action("Reload Config", #selector(reloadConfig)))
        menu.addItem(action("Show History in Finder", #selector(showHistory)))

        let login = action("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Quit SpeechToPrompt", #selector(quit), key: "q"))
    }

    private func statusLine() -> String {
        switch controller.status {
        case .loading(let s): return s
        case .ready: return "Ready · \(controller.engineName)"
        case .recording(let m): return "Listening (\(m.rawValue))…"
        case .processing(let m): return "Transcribing (\(m.rawValue))…"
        case .error(let s): return "Error: \(s)"
        }
    }

    private func describe(_ h: HotkeyConfig) -> String {
        "\(h.behavior == .hold ? "hold" : "tap") \(h.key.displayName)"
    }

    // MARK: Menu item helpers

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    // MARK: Actions

    @objc private func copyLast() {
        guard let text = controller.lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = EngineKind(rawValue: raw) else { return }
        controller.setEngine(kind)
    }

    @objc private func openPermission(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = Permission(rawValue: raw) else { return }
        if p.isGranted { p.openSettings(); return }
        Task {
            await p.request()
            if !p.isGranted { p.openSettings() }
        }
    }

    @objc private func openConfig() {
        _ = try? AppConfig.loadOrCreate(at: controller.paths.configFile)
        NSWorkspace.shared.open(controller.paths.configFile)
    }

    @objc private func reloadConfig() { controller.reloadConfig() }

    @objc private func showHistory() {
        let fm = FileManager.default
        let dir = controller.paths.supportDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: controller.paths.historyFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([controller.paths.historyFile])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.app.error("Launch at Login failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
