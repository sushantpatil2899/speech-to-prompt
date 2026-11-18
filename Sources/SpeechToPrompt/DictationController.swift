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
/// Raw mode: transcribe → paste. Clean mode: transcribe → local LLM rewrite (with guardrails and
/// fallback to the raw transcript) → paste, then a Cleaned / Raw toggle on the overlay for 30 s.
/// The clipboard is restored after every paste.
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
    private let swapGuard = SwapGuard()
    private var rewriter: Rewriter?
    private(set) var llmStatus: RewriterStatus = .disabled
    /// Both versions of the last clean-mode dictation, for the overlay toggle.
    private var cleanOutcome: OverlayModel.CleanOutcome?
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
        hotkeys.onAnyKeyDown = { [weak self] in
            MainActor.assumeIsolated { self?.swapGuard.noteKeyDown() }
        }
        hotkeys.onMouseDown = { [weak self] point in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.swapGuard.noteMouseDown(cgPoint: point, ignoring: self.overlay.visibleFrame)
            }
        }
        overlay.model.onSelectVersion = { [weak self] version in self?.selectVersion(version) }
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
        rebuildRewriter()
    }

    var llmName: String { config.llm.model }

    private func rebuildRewriter() {
        let llm = config.llm
        guard llm.enabled else { rewriter = nil; llmStatus = .disabled; return }
        if let problem = llm.problems().first {
            rewriter = nil
            llmStatus = .misconfigured(problem)
            return
        }
        let r = OllamaRewriter(config: llm)
        rewriter = r
        llmStatus = .misconfigured("checking Ollama…")
        Task { await self.refreshRewriter(r, warm: true) }
    }

    /// Checks Ollama and, if the model is there, loads it into memory so the first clean
    /// dictation doesn't pay the load time.
    private func refreshRewriter(_ r: Rewriter, warm: Bool) async {
        let s = await r.status()
        guard rewriter === r else { return }
        llmStatus = s
        onStatusChange?(status)
        guard s == .ready, warm else {
            Log.app.notice("Clean mode LLM: \(s.summary, privacy: .public)")
            return
        }
        let t0 = LatencyTimer.now()
        do {
            try await r.warmUp()
            Log.app.info("LLM \(r.name, privacy: .public) loaded and warm in \(Int((LatencyTimer.now() - t0) * 1000)) ms")
        } catch {
            Log.app.error("LLM warm-up failed: \(String(describing: error), privacy: .public)")
        }
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
        cleanOutcome = nil
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

            // Clean mode: rewrite with the local LLM; on any problem paste the raw transcript.
            var finalText = text
            var clean: OverlayModel.CleanOutcome?
            var llmNote: String?
            if mode == .clean, !text.isEmpty {
                if self.active == nil { self.overlay.showRewriting() }
                let rewrite = await self.cleanUp(text)
                timer.mark("llmDone")
                clean = rewrite.outcome
                llmNote = rewrite.note
                if rewrite.outcome.showing == .cleaned, let cleaned = rewrite.outcome.cleaned { finalText = cleaned }
            }
            if let llmNote { note = [note, llmNote].compactMap { $0 }.joined(separator: "; ") }

            // Paste first: everything after this is off the latency path.
            var pasted: Bool?
            if !finalText.isEmpty {
                switch self.paster.insert(finalText, autoPaste: config.autoPaste) {
                case .pasted:
                    pasted = true
                case .copiedOnly(let why):
                    pasted = false
                    note = [note, "not pasted: \(why)"].compactMap { $0 }.joined(separator: "; ")
                }
                timer.mark("pasted")
                if pasted == true { self.swapGuard.arm() } else { self.swapGuard.disarm() }
            }
            self.cleanOutcome = clean
            self.showOutcome(mode: mode, text: finalText, clean: clean, pasted: pasted, failed: result == nil)

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
                mode: mode, text: finalText, engineText: text, cleaned: clean?.cleaned,
                usedFallback: clean.map { $0.showing == .raw } ?? false, note: note,
                decision: result?.decision, audioSeconds: Double(samples.count) / PCM.sampleRate,
                timer: timer, frontmostApp: rec.frontmostApp, audioPath: audioPath, engine: pipeline.engine.name,
                pasted: pasted)
        }
    }

    /// Runs the LLM and the guardrails. Never throws: every failure becomes "paste raw".
    private func cleanUp(_ transcript: String) async -> (outcome: OverlayModel.CleanOutcome, note: String?) {
        let rawWords = transcript.split(whereSeparator: { $0.isWhitespace }).count
        guard let rewriter else {
            let why = llmStatus.summary
            return (.init(raw: transcript, cleaned: nil, showing: .raw, cleanedRejected: false,
                          detail: "Raw pasted · LLM \(why)"), "LLM not used: \(why)")
        }
        do {
            let r = try await rewriter.rewrite(transcript)
            var stats = "\(Int(r.milliseconds)) ms"
            if let n = r.outputTokens { stats += ", \(n) output tokens" }
            if let load = r.loadMilliseconds, load > 50 { stats += String(format: ", model load %.0f ms", load) }
            Log.app.info("LLM \(stats, privacy: .public)")
            switch r.verdict {
            case .accept(let cleaned):
                let words = cleaned.split(whereSeparator: { $0.isWhitespace }).count
                return (.init(raw: transcript, cleaned: cleaned, showing: .cleaned, cleanedRejected: false,
                              detail: "Cleaned · \(rawWords) → \(words) words"), nil)
            case .reject(let reason, let output):
                Log.app.notice("LLM output rejected (\(reason, privacy: .public)): \(output, privacy: .public)")
                return (.init(raw: transcript, cleaned: output.isEmpty ? nil : output, showing: .raw,
                              cleanedRejected: true, detail: "Raw pasted · cleaned text \(reason)"),
                        "LLM output rejected: \(reason)")
            }
        } catch {
            let message = String(describing: error)
            Log.app.error("LLM failed: \(message, privacy: .public)")
            // Ollama restarted or the model was unloaded: reload it in the background for next time.
            Task { await self.refreshRewriter(rewriter, warm: true) }
            return (.init(raw: transcript, cleaned: nil, showing: .raw, cleanedRejected: false,
                          detail: "Raw pasted · LLM \(message)"), "LLM failed: \(message)")
        }
    }

    /// The overlay's Clean / Raw toggle.
    private func selectVersion(_ version: OverlayModel.Version) {
        guard var outcome = cleanOutcome, outcome.showing != version else { return }
        guard let newText = version == .cleaned ? outcome.cleaned : outcome.raw else { return }
        if let reason = swapGuard.blockReason() {
            // Not safe to undo in place: hand over the other version on the clipboard instead.
            _ = paster.insert(newText, autoPaste: false)
            outcome.detail = "\(version == .cleaned ? "Cleaned" : "Raw") copied: \(reason). Paste with ⌘V"
            Log.app.info("Toggle → \(version == .cleaned ? "cleaned" : "raw", privacy: .public): copied only (\(reason, privacy: .public))")
        } else {
            paster.undoLastPaste()
            outcome.showing = version
            outcome.detail = version == .cleaned ? "Cleaned (switched)" : "Raw (switched)"
            Log.app.info("Toggle → \(version == .cleaned ? "cleaned" : "raw", privacy: .public): replaced in place")
            Task {
                // Let the app process the undo before pasting.
                try? await Task.sleep(nanoseconds: 80_000_000)
                if case .pasted = self.paster.insert(newText, autoPaste: true) { self.swapGuard.arm() }
            }
        }
        cleanOutcome = outcome
        overlay.updateCleanDone(outcome, seconds: config.cleanToggleSeconds)
    }

    private func showOutcome(mode: DictationMode, text: String, clean: OverlayModel.CleanOutcome?, pasted: Bool?, failed: Bool) {
        // A new recording already started: keep its listening overlay.
        guard active == nil else { return }
        if let clean, pasted == true {
            overlay.showCleanDone(clean, seconds: config.cleanToggleSeconds)
            return
        }
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
            overlay.showDone(mode, text: text, detail: "Pasted")
        }
    }

    /// Log, menu, history.
    private func report(
        mode: DictationMode, text: String, engineText: String, cleaned: String?, usedFallback: Bool,
        note: String?, decision: VADDecision?,
        audioSeconds: Double, timer: LatencyTimer, frontmostApp: String?, audioPath: String?, engine: String,
        pasted: Bool?
    ) {
        if !text.isEmpty { lastTranscript = text }
        var noteParts: [String] = []
        if let note { noteParts.append(note) }

        if mode == .clean, !engineText.isEmpty, engineText != text {
            Log.app.notice("[clean] raw: \(engineText, privacy: .public)")
        }
        Log.app.notice("[\(mode.rawValue, privacy: .public)] \(text.isEmpty ? "(nothing)" : text, privacy: .public)")
        if !noteParts.isEmpty { Log.app.notice("note: \(noteParts.joined(separator: "; "), privacy: .public)") }
        Log.app.notice("latency: \(timer.summary(), privacy: .public)")

        if config.writeHistory {
            let record = HistoryRecord(
                mode: mode, engine: engine, llmModel: mode == .clean ? rewriter?.name : nil,
                rawText: engineText, cleanedText: cleaned, finalText: text,
                usedFallback: usedFallback, note: noteParts.isEmpty ? nil : noteParts.joined(separator: "; "),
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
