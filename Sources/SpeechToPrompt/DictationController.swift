import AppKit
import DictateCore
import DictateKit

/// What the menu bar shows.
enum AppStatus: Equatable {
    case loading(String)
    case ready
    case recording(DictationMode)
    case processing(DictationMode)
    case error(String)
}

/// Owns the hotkeys, the recorder and the speech pipeline, and runs one dictation at a time.
///
/// Stage 2: the transcript is pasted into the focused field (clipboard is restored afterwards),
/// with the overlay showing listening → processing → done. The clean-mode LLM rewrite is stage 3;
/// until then clean mode pastes the raw transcript.
@MainActor
final class DictationController {
    let paths = AppPaths.standard
    private(set) var config = AppConfig()
    private(set) var status: AppStatus = .loading("Starting…") { didSet { onStatusChange?(status) } }
    private(set) var lastTranscript: String?
    private(set) var configProblem: String?

    var onStatusChange: ((AppStatus) -> Void)?

    private let recorder = AudioRecorder()
    private let paster = Paster()
    private let overlay = OverlayController()
    private let hotkeys = HotkeyMonitor()
    private let machine = HotkeyStateMachine(settings: .init(config: AppConfig()))
    private var pipeline: TranscriptionPipeline?
    private var history: HistoryLog
    private var engineReady = false
    private var loadTask: Task<Void, Never>?
    private var tapRetryTimer: Timer?
    private var maxDurationTimer: Timer?

    private struct ActiveRecording {
        var mode: DictationMode
        var timer: LatencyTimer
        var stream: STTStream?
        var frontmostApp: String?
    }
    private var active: ActiveRecording?

    init() {
        history = HistoryLog(url: paths.historyFile)
    }

    var engineName: String { pipeline?.engine.name ?? config.engine.kind.displayName }

    // MARK: Startup

    func start() {
        reloadConfig()
        hotkeys.onInput = { [weak self] input in
            MainActor.assumeIsolated { self?.handle(input) }
        }
        Task {
            if !Permission.microphone.isGranted { await Permission.microphone.request() }
            startHotkeys()
            // Needed to send ⌘V. macOS shows its prompt once; after that, use menu → Permissions.
            if !Permission.accessibility.isGranted { Permission.accessibility.requestOnce() }
        }
    }

    /// Reads config.json (creating it with defaults the first time) and rebuilds the engine.
    func reloadConfig() {
        do {
            config = try AppConfig.loadOrCreate(at: paths.configFile)
            let problems = config.validationErrors()
            configProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
        } catch {
            configProblem = "config.json could not be read (\(error.localizedDescription)); using defaults."
            config = AppConfig()
        }
        if let configProblem { Log.app.error("\(configProblem, privacy: .public)") }
        machine.settings = .init(config: config)
        paster.restoreDelay = config.pasteRestoreDelaySeconds
        overlay.enabled = config.showOverlay
        overlay.doneSeconds = config.overlayDoneSeconds
        history = HistoryLog(url: paths.historyFile)
        rebuildEngine()
    }

    func setEngine(_ kind: EngineKind) {
        guard kind != config.engine.kind else { return }
        config.engine.kind = kind
        do { try config.save(to: paths.configFile) } catch {
            Log.app.error("Could not save config: \(error.localizedDescription, privacy: .public)")
        }
        rebuildEngine()
    }

    private func rebuildEngine() {
        loadTask?.cancel()
        engineReady = false
        let engine = EngineFactory.make(config.engine, paths: paths)
        let vad = EngineFactory.makeVAD(config.vad, paths: paths)
        let pipeline = TranscriptionPipeline(engine: engine, vad: vad, config: config)
        self.pipeline = pipeline
        status = .loading("Loading \(engine.name)…")
        loadTask = Task {
            let t0 = LatencyTimer.now()
            do {
                try await engine.prepare()
                guard self.pipeline === pipeline else { return }
                self.engineReady = true
                self.status = .ready
                Log.app.info("Engine ready: \(engine.name, privacy: .public) in \(Int((LatencyTimer.now() - t0) * 1000)) ms; VAD: \(vad.name, privacy: .public)")
            } catch {
                guard self.pipeline === pipeline else { return }
                self.status = .error(String(describing: error))
                Log.app.error("Engine failed to load: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func startHotkeys() {
        if hotkeys.start() {
            tapRetryTimer?.invalidate()
            tapRetryTimer = nil
            return
        }
        // First launch: ask for Input Monitoring, then retry until it's granted.
        // (macOS may require the app to be relaunched after granting; the retry covers both cases.)
        Permission.inputMonitoring.requestOnce()
        tapRetryTimer?.invalidate()
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hotkeys.start() {
                    self.tapRetryTimer?.invalidate()
                    self.tapRetryTimer = nil
                    Log.app.info("Input Monitoring granted; hotkeys active")
                    self.onStatusChange?(self.status)
                }
            }
        }
    }

    var hotkeysActive: Bool { hotkeys.isRunning }

    // MARK: Hotkey handling

    private func handle(_ input: HotkeyInput) {
        guard let action = machine.handle(input) else { return }
        switch action {
        case .startRecording(let mode): beginRecording(mode, at: input.time)
        case .stopRecording(let mode): finishRecording(mode, at: input.time)
        case .cancelRecording(let mode, let reason): cancelRecording(mode, reason: reason.rawValue)
        }
    }

    private func beginRecording(_ mode: DictationMode, at time: Double) {
        guard engineReady, let pipeline else {
            Log.app.notice("Hotkey pressed but the engine is not ready (\(String(describing: self.status), privacy: .public))")
            if case .error(let message) = status {
                overlay.showMessage("Speech engine failed: \(message)", isError: true, seconds: 4)
            } else {
                overlay.showMessage("Still loading the speech model…", isError: false)
            }
            machine.reset()
            return
        }
        var timer = LatencyTimer()
        timer.mark("keyDown", at: time)

        var stream: STTStream?
        do {
            stream = try pipeline.engine.makeStream(context: pipeline.context)
        } catch {
            Log.stt.error("Could not start streaming session: \(String(describing: error), privacy: .public)")
        }
        if let stream {
            recorder.onBuffer = { buffer in stream.append(buffer) }
        } else {
            recorder.onBuffer = nil
        }
        let overlay = self.overlay
        recorder.onLevel = { rms in
            DispatchQueue.main.async { MainActor.assumeIsolated { overlay.pushLevel(rms) } }
        }

        do {
            try recorder.start()
        } catch {
            Log.audio.error("Recorder failed to start: \(String(describing: error), privacy: .public)")
            if let stream { Task { await stream.cancel() } }
            overlay.showMessage("Microphone unavailable: \(error.localizedDescription)", isError: true, seconds: 4)
            machine.reset()
            return
        }
        timer.mark("micStarted")
        overlay.showListening(mode)
        active = ActiveRecording(
            mode: mode, timer: timer, stream: stream,
            frontmostApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        status = .recording(mode)
        Log.app.info("Recording (\(mode.rawValue, privacy: .public)); mic start \(Int(timer.ms(from: "keyDown", to: "micStarted") ?? 0)) ms")

        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: config.maxRecordingSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let mode = self.active?.mode else { return }
                Log.app.notice("Maximum recording length reached")
                self.machine.reset()
                self.finishRecording(mode, at: LatencyTimer.now())
            }
        }
    }

    private func cancelRecording(_ mode: DictationMode, reason: String) {
        maxDurationTimer?.invalidate()
        guard let rec = active else { return }
        active = nil
        recorder.stop()
        recorder.onBuffer = nil
        recorder.onLevel = nil
        if let stream = rec.stream { Task { await stream.cancel() } }
        overlay.hide()
        status = engineReady ? .ready : status
        Log.app.info("Recording cancelled (\(reason, privacy: .public))")
    }

    private func finishRecording(_ mode: DictationMode, at time: Double) {
        maxDurationTimer?.invalidate()
        guard var rec = active, let pipeline else { return }
        active = nil
        rec.timer.mark("keyUp", at: time)
        let samples = recorder.stop()
        recorder.onBuffer = nil
        recorder.onLevel = nil
        rec.timer.mark("audioStopped")
        status = .processing(mode)
        overlay.showProcessing(mode)

        let config = self.config
        let paths = self.paths
        Task {
            var timer = rec.timer
            var note: String?
            var result: PipelineResult?
            do {
                result = try await pipeline.run(samples: samples, stream: rec.stream, timer: &timer)
                note = result?.note
            } catch {
                note = "error: \(error)"
                Log.stt.error("Transcription failed: \(String(describing: error), privacy: .public)")
            }

            let text = result?.text ?? ""

            // Paste first: everything after this is off the latency path.
            var pasted: Bool?
            if !text.isEmpty {
                switch self.paster.insert(text, autoPaste: config.autoPaste) {
                case .pasted:
                    pasted = true
                case .copiedOnly(let why):
                    pasted = false
                    note = [note, "not pasted: \(why)"].compactMap { $0 }.joined(separator: "; ")
                }
                timer.mark("pasted")
            }
            self.showOutcome(mode: mode, text: text, pasted: pasted, failed: result == nil)

            var audioPath: String?
            if config.saveAudio {
                let url = paths.recordingsDirectory.appendingPathComponent(Self.fileStamp() + "-\(mode.rawValue).wav")
                do {
                    try WAV.write(samples: samples, sampleRate: Int(PCM.sampleRate), to: url)
                    audioPath = url.path
                } catch {
                    Log.app.error("Could not save audio: \(error.localizedDescription, privacy: .public)")
                }
            }

            self.report(
                mode: mode, text: text, engineText: result?.engineText ?? "", note: note,
                decision: result?.decision, audioSeconds: Double(samples.count) / PCM.sampleRate,
                timer: timer, frontmostApp: rec.frontmostApp, audioPath: audioPath, engine: pipeline.engine.name,
                pasted: pasted)
        }
    }

    private func showOutcome(mode: DictationMode, text: String, pasted: Bool?, failed: Bool) {
        // A new recording already started: keep its listening overlay.
        guard active == nil else { return }
        if failed {
            overlay.showMessage("Transcription failed (see log)", isError: true, seconds: 3)
        } else if text.isEmpty {
            overlay.showMessage("No speech detected", isError: false, seconds: 1.2)
        } else if pasted == false {
            if config.autoPaste {
                overlay.showMessage("Copied, not pasted: grant Accessibility (menu → Permissions)", isError: true, seconds: 4)
            } else {
                overlay.showDone(mode, text: text, detail: "Copied to clipboard")
            }
        } else {
            overlay.showDone(mode, text: text, detail: mode == .clean ? "Pasted raw · cleanup comes in stage 3" : "Pasted")
        }
    }

    /// Log, menu, history.
    private func report(
        mode: DictationMode, text: String, engineText: String, note: String?, decision: VADDecision?,
        audioSeconds: Double, timer: LatencyTimer, frontmostApp: String?, audioPath: String?, engine: String,
        pasted: Bool?
    ) {
        if !text.isEmpty { lastTranscript = text }
        var noteParts: [String] = []
        if let note { noteParts.append(note) }
        if mode == .clean { noteParts.append("clean mode: LLM rewrite not built yet (stage 3); raw transcript pasted") }

        Log.app.notice("[\(mode.rawValue, privacy: .public)] \(text.isEmpty ? "(nothing)" : text, privacy: .public)")
        if !noteParts.isEmpty { Log.app.notice("note: \(noteParts.joined(separator: "; "), privacy: .public)") }
        Log.app.notice("latency: \(timer.summary(), privacy: .public)")

        if config.writeHistory {
            let record = HistoryRecord(
                mode: mode, engine: engine, rawText: engineText, cleanedText: nil, finalText: text,
                usedFallback: false, note: noteParts.isEmpty ? nil : noteParts.joined(separator: "; "),
                audioSeconds: audioSeconds, speechSeconds: decision?.speechSeconds ?? 0,
                latencyMS: timer.stageDurationsMS(), frontmostApp: frontmostApp, audioPath: audioPath,
                pasted: pasted)
            do { try history.append(record) } catch {
                Log.app.error("Could not write history: \(error.localizedDescription, privacy: .public)")
            }
        }
        status = engineReady ? .ready : status
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

private extension HotkeyInput {
    var time: Double {
        switch self {
        case .modifierDown(_, let t), .modifierUp(_, let t): return t
        case .otherKeyDown(let t), .escape(let t): return t
        }
    }
}

private extension Permission {
    /// Shows the system prompt the first time only (it would otherwise reappear on every launch).
    func requestOnce() {
        let key = "askedFor.\(rawValue)"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { await request() }
    }
}
