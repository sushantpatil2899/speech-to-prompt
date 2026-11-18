// dictate-cli: recording eval clips and running the app's exact speech pipeline on files.
//
//   dictate-cli record --prompts eval/prompts.txt --out eval/clips [--overwrite] [--only N]
//   dictate-cli transcribe --engine whisper|apple|apple-dictation [options] FILE...
//   dictate-cli rewrite [--model M] [--text "..."] [--json]   (clean-mode LLM, same code as the app)
//   dictate-cli locales
//   dictate-cli vad FILE...
//
// Run with no arguments for full help.

import AVFoundation
import DictateCore
import DictateKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage:
  dictate-cli record --prompts FILE --out DIR [--overwrite] [--only N]
      Shows each prompt, records it (Enter to start, Enter to stop) and saves
      DIR/NNN.wav plus DIR/NNN.txt (the reference transcript; edit it if you misspoke).
      Prompt lines:  plain text              → read it aloud
                     [silence 5]             → stay silent for 5 s (reference is empty)
                     [noise 5: typing]       → make that noise for 5 s, don't speak
                     # comment / blank line  → ignored

  dictate-cli transcribe --engine ENGINE [options] FILE...
      ENGINE: whisper | apple | apple-dictation
      --locale ID       Apple engines (default from config, e.g. en-IN)
      --model PATH      whisper model file (default from config)
      --beam N          whisper beam size (default greedy)
      --no-fallback     disable whisper temperature fallback
      --no-vad          skip the VAD gate (to see raw hallucination behaviour)
      --vocab "a,b,c"   vocabulary hint (default from config)
      --json            one JSON object per line (used by eval/compare.py)

  dictate-cli rewrite [--model NAME] [--timeout S] [--text "..."] [--json]
      Runs the clean-mode rewrite (prompt + local Ollama + guardrails) exactly as the app does.
      Without --text, reads one transcript per stdin line (plain text, or JSON {"id","transcript"}).
      --timeout S       per-request limit (default from config, 3 s); a timeout = raw fallback in the app

  dictate-cli locales
      Lists Apple speech locales supported / installed on this Mac.

  dictate-cli vad FILE...
      Prints the speech segments the VAD finds.
"""

// MARK: Argument parsing

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: ArraySlice<String>, valued: Set<String>) {
        var it = argv.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valued.contains(name) {
                    guard let v = it.next() else { fail("missing value for --\(name)") }
                    options[name] = v
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(a)
            }
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func loadConfig() -> AppConfig {
    let paths = AppPaths.standard
    return (try? AppConfig.load(from: paths.configFile)) ?? AppConfig()
}

func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

// MARK: Commands

func runTranscribe(_ args: Args) async {
    var config = loadConfig()
    if let e = args.options["engine"] {
        guard let kind = EngineKind(rawValue: e) else { fail("unknown engine \(e)") }
        config.engine.kind = kind
    }
    if let l = args.options["locale"] { config.engine.locale = l }
    if let m = args.options["model"] { config.engine.whisperModel = m }
    if let b = args.options["beam"] { config.engine.whisperBeamSize = Int(b) ?? 0 }
    if args.flags.contains("no-fallback") { config.engine.whisperTemperatureFallback = false }
    if args.flags.contains("no-vad") { config.vad.enabled = false }
    if let v = args.options["vocab"] {
        config.vocabulary = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    let json = args.flags.contains("json")
    guard !args.positional.isEmpty else { fail("no input files") }

    let paths = AppPaths.standard
    let engine = EngineFactory.make(config.engine, paths: paths)
    let vad = EngineFactory.makeVAD(config.vad, paths: paths)
    let pipeline = TranscriptionPipeline(engine: engine, vad: vad, config: config)

    let t0 = LatencyTimer.now()
    do {
        try await engine.prepare()
    } catch {
        if json { print(jsonLine(["event": "error", "engine": engine.name, "error": String(describing: error)])) }
        fail("\(engine.name): \(error)")
    }
    let prepareMS = (LatencyTimer.now() - t0) * 1000
    if json {
        print(jsonLine(["event": "ready", "engine": engine.name, "vad": config.vad.enabled ? vad.name : "off",
                        "prepare_ms": Int(prepareMS)]))
    } else {
        eprint("\(engine.name) ready in \(Int(prepareMS)) ms (VAD: \(config.vad.enabled ? vad.name : "off"))")
    }

    for path in args.positional {
        let url = URL(fileURLWithPath: path)
        do {
            let samples = try AudioFileLoader.load(url)
            var timer = LatencyTimer()
            timer.mark("start")
            let result = try await pipeline.run(samples: samples, stream: nil, timer: &timer)
            let audioSeconds = Double(samples.count) / PCM.sampleRate
            let sttMS = timer.ms(from: "vadDone", to: "sttDone") ?? 0
            if json {
                var obj: [String: Any] = [
                    "file": path, "engine": engine.name, "text": result.text, "engine_text": result.engineText,
                    "audio_s": audioSeconds, "speech_s": result.decision.speechSeconds,
                    "skipped": result.decision.skip, "vad_ms": timer.ms(from: "start", to: "vadDone") ?? 0,
                    "stt_ms": sttMS,
                    "trim_start_s": Double(result.decision.trimRange.lowerBound) / PCM.sampleRate,
                    "trim_end_s": Double(result.decision.trimRange.upperBound) / PCM.sampleRate,
                ]
                if let note = result.note { obj["note"] = note }
                if let w = engine as? WhisperCppEngine, !result.decision.skip {
                    obj["max_no_speech_prob"] = Double(w.lastMaxNoSpeechProb)
                }
                print(jsonLine(obj))
            } else {
                let shown = result.text.isEmpty ? "(nothing — \(result.note ?? "empty"))" : result.text
                print("\(url.lastPathComponent)\t\(String(format: "%.1f s audio, %.0f ms", audioSeconds, sttMS))\t\(shown)")
            }
        } catch {
            if json {
                print(jsonLine(["file": path, "engine": engine.name, "error": String(describing: error)]))
            } else {
                eprint("\(path): \(error)")
            }
        }
    }
}

func runRewrite(_ args: Args) async {
    var config = loadConfig()
    if let m = args.options["model"] { config.llm.model = m }
    if let t = args.options["timeout"], let v = Double(t) { config.llm.timeoutSeconds = v }
    config.llm.enabled = true
    let json = args.flags.contains("json")
    if let problem = config.llm.problems().first { fail(problem) }

    let rewriter = OllamaRewriter(config: config.llm)
    let status = await rewriter.status()
    guard status == .ready else {
        if json { print(jsonLine(["event": "error", "model": config.llm.model, "error": status.summary])) }
        fail("\(rewriter.name): \(status.summary)")
    }
    let t0 = LatencyTimer.now()
    do { try await rewriter.warmUp() } catch {
        if json { print(jsonLine(["event": "error", "model": config.llm.model, "error": String(describing: error)])) }
        fail("warm-up failed: \(error)")
    }
    let warmMS = Int((LatencyTimer.now() - t0) * 1000)
    if json {
        print(jsonLine(["event": "ready", "model": config.llm.model, "warmup_ms": warmMS]))
    } else {
        eprint("\(rewriter.name) ready (warm-up \(warmMS) ms)")
    }

    var inputs: [(id: String, text: String)] = []
    if let text = args.options["text"] {
        inputs.append(("text", text))
    } else {
        var n = 0
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            n += 1
            if trimmed.hasPrefix("{"),
               let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
               let t = obj["transcript"] as? String {
                inputs.append(((obj["id"] as? String) ?? String(n), t))
            } else {
                inputs.append((String(n), trimmed))
            }
        }
    }

    for input in inputs {
        do {
            let r = try await rewriter.rewrite(input.text)
            var verdict = "accept", reason = "", cleaned = "", finalText = input.text
            switch r.verdict {
            case .accept(let t): cleaned = t; finalText = t
            case .reject(let why, let out): verdict = "reject"; reason = why; cleaned = out
            }
            if json {
                var obj: [String: Any] = [
                    "id": input.id, "model": config.llm.model, "transcript": input.text,
                    "model_output": r.modelOutput, "cleaned": cleaned, "verdict": verdict, "final": finalText,
                    "ms": r.milliseconds,
                ]
                if !reason.isEmpty { obj["reason"] = reason }
                if let n = r.outputTokens { obj["output_tokens"] = n }
                if let n = r.promptTokens { obj["prompt_tokens"] = n }
                print(jsonLine(obj))
            } else {
                print("[\(input.id)] \(Int(r.milliseconds)) ms  \(verdict)\(reason.isEmpty ? "" : " (\(reason))")")
                print("  said:    \(input.text)")
                print("  cleaned: \(cleaned)")
            }
        } catch {
            if json {
                print(jsonLine(["id": input.id, "model": config.llm.model, "transcript": input.text,
                                "error": String(describing: error), "final": input.text]))
            } else {
                print("[\(input.id)] ERROR \(error) → raw would be pasted")
            }
        }
    }
}

func runVAD(_ args: Args) {
    let config = loadConfig()
    let vad = EngineFactory.makeVAD(config.vad, paths: AppPaths.standard)
    for path in args.positional {
        do {
            let samples = try AudioFileLoader.load(URL(fileURLWithPath: path))
            let segs = vad.speechSegments(in: samples, sampleRate: PCM.sampleRate)
            let d = VADGate.decide(segments: segs, sampleCount: samples.count, sampleRate: PCM.sampleRate,
                                   minSpeechSeconds: config.vad.minSpeechSeconds, padSeconds: config.vad.padSeconds)
            let list = segs.map { String(format: "%.2f–%.2f", $0.start, $0.end) }.joined(separator: ", ")
            print("\(path): \(vad.name) speech \(String(format: "%.2f", d.speechSeconds)) s of \(String(format: "%.2f", d.audioSeconds)) s\(d.skip ? " → SKIP" : "")  [\(list)]")
        } catch {
            eprint("\(path): \(error)")
        }
    }
}

struct Prompt {
    enum Kind { case speech(String), silence(Double), noise(Double, String) }
    var kind: Kind

    static func parse(_ line: String) -> Prompt? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { return nil }
        if t.hasPrefix("[silence"), let n = Double(t.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: " ]"))) {
            return Prompt(kind: .silence(n))
        }
        if t.hasPrefix("[noise") {
            let inner = t.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " ]"))
            let parts = inner.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return Prompt(kind: .noise(Double(parts.first ?? "5") ?? 5, parts.count > 1 ? parts[1] : "background noise"))
        }
        return Prompt(kind: .speech(t))
    }
}

func runRecord(_ args: Args) async {
    guard let promptsPath = args.options["prompts"], let outPath = args.options["out"] else {
        fail("record needs --prompts FILE and --out DIR")
    }
    let lines: [String]
    do { lines = try String(contentsOfFile: promptsPath, encoding: .utf8).components(separatedBy: .newlines) } catch {
        fail("cannot read \(promptsPath): \(error)")
    }
    let prompts = lines.compactMap(Prompt.parse)
    let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let overwrite = args.flags.contains("overwrite")
    let only = args.options["only"].flatMap(Int.init)

    if !(await AudioRecorder.requestMicrophonePermission()) {
        fail("microphone access denied. Allow your terminal app in System Settings → Privacy & Security → Microphone.")
    }

    let recorder = AudioRecorder()
    print("Recording \(prompts.count) clips into \(outDir.path). Speak the way you normally dictate.")
    print("Commands at each prompt: Enter = start, s = skip, q = quit.\n")

    var index = 0
    while index < prompts.count {
        let number = index + 1
        defer { index += 1 }
        if let only, only != number { continue }
        let id = String(format: "%03d", number)
        let wav = outDir.appendingPathComponent("\(id).wav")
        let txt = outDir.appendingPathComponent("\(id).txt")
        if !overwrite, FileManager.default.fileExists(atPath: wav.path) {
            print("[\(id)] exists, skipping (use --overwrite to redo)")
            continue
        }

        let prompt = prompts[index]
        let reference: String
        var fixedDuration: Double? = nil
        switch prompt.kind {
        case .speech(let s):
            reference = s
            print("[\(id)/\(prompts.count)] Say:\n    \(s)")
        case .silence(let d):
            reference = ""
            fixedDuration = d
            print("[\(id)/\(prompts.count)] Stay SILENT for \(Int(d)) s (records automatically).")
        case .noise(let d, let what):
            reference = ""
            fixedDuration = d
            print("[\(id)/\(prompts.count)] Make this noise for \(Int(d)) s WITHOUT speaking: \(what)")
        }

        print("  Enter to start (s = skip, q = quit): ", terminator: "")
        let cmd = readLine()?.lowercased() ?? "q"
        if cmd == "q" { break }
        if cmd == "s" { continue }

        do { try recorder.start() } catch { fail("recorder: \(error)") }
        if let d = fixedDuration {
            print("  ● recording for \(Int(d)) s…")
            try? await Task.sleep(nanoseconds: UInt64(d * 1e9))
        } else {
            print("  ● recording… press Enter to stop ", terminator: "")
            _ = readLine()
        }
        let samples = recorder.stop()
        do {
            try WAV.write(samples: samples, sampleRate: Int(PCM.sampleRate), to: wav)
            try (reference + "\n").write(to: txt, atomically: true, encoding: .utf8)
            print(String(format: "  saved %@ (%.1f s)\n", wav.lastPathComponent, Double(samples.count) / PCM.sampleRate))
        } catch {
            eprint("  could not save: \(error)")
        }
    }
    print("Done. If you deviated from a prompt, edit that clip's .txt so it matches what you actually said.")
}

// MARK: Main

var argv = CommandLine.arguments.dropFirst()
guard let command = argv.first else { print(usage); exit(0) }
argv = argv.dropFirst()

switch command {
case "transcribe":
    await runTranscribe(Args(argv, valued: ["engine", "locale", "model", "beam", "vocab"]))
case "record":
    await runRecord(Args(argv, valued: ["prompts", "out", "only"]))
case "rewrite":
    await runRewrite(Args(argv, valued: ["model", "timeout", "text"]))
case "locales":
    print(await AppleSpeechEngine.localeReport())
case "vad":
    runVAD(Args(argv, valued: []))
case "-h", "--help", "help":
    print(usage)
default:
    print(usage)
    exit(1)
}
