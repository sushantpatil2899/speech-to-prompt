import XCTest
@testable import DictateCore

final class VADGateTests: XCTestCase {
    func testSkipsWhenSpeechTooShort() {
        let d = VADGate.decide(
            segments: [SpeechSegment(start: 1.0, end: 1.2)], sampleCount: 16000 * 3,
            sampleRate: 16000, minSpeechSeconds: 0.3, padSeconds: 0.25)
        XCTAssertTrue(d.skip)
        XCTAssertEqual(d.speechSeconds, 0.2, accuracy: 1e-9)
    }

    func testSkipsWhenNoSegments() {
        let d = VADGate.decide(segments: [], sampleCount: 16000, sampleRate: 16000, minSpeechSeconds: 0.3, padSeconds: 0.25)
        XCTAssertTrue(d.skip)
        XCTAssertEqual(d.trimmed([Float](repeating: 0, count: 16000)).count, 0)
    }

    func testTrimsWithPaddingButKeepsInnerSilence() {
        let d = VADGate.decide(
            segments: [SpeechSegment(start: 1.0, end: 1.5), SpeechSegment(start: 2.5, end: 3.0)],
            sampleCount: 16000 * 5, sampleRate: 16000, minSpeechSeconds: 0.3, padSeconds: 0.25)
        XCTAssertFalse(d.skip)
        XCTAssertEqual(d.speechSeconds, 1.0, accuracy: 1e-9)
        XCTAssertEqual(d.trimRange, Int(0.75 * 16000)..<Int(3.25 * 16000))
    }

    func testPaddingClampedToClip() {
        let d = VADGate.decide(
            segments: [SpeechSegment(start: 0.05, end: 0.95)], sampleCount: 16000,
            sampleRate: 16000, minSpeechSeconds: 0.3, padSeconds: 0.25)
        XCTAssertEqual(d.trimRange, 0..<16000)
    }

    func testSegmentsBeyondClipAreClamped() {
        let d = VADGate.decide(
            segments: [SpeechSegment(start: 0.5, end: 9)], sampleCount: 16000,
            sampleRate: 16000, minSpeechSeconds: 0.3, padSeconds: 0)
        XCTAssertEqual(d.speechSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(d.trimRange, 8000..<16000)
    }
}

final class EnergyVADTests: XCTestCase {
    private func tone(seconds: Double, amplitude: Float, rate: Double = 16000) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }

    private func noise(seconds: Double, amplitude: Float, rate: Double = 16000) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { _ in Float.random(in: -amplitude...amplitude, using: &g) }
    }

    func testSilenceHasNoSpeech() {
        XCTAssertTrue(EnergyVAD().speechSegments(in: [Float](repeating: 0, count: 32000), sampleRate: 16000).isEmpty)
    }

    func testSteadyLowNoiseHasNoSpeech() {
        XCTAssertTrue(EnergyVAD().speechSegments(in: noise(seconds: 2, amplitude: 0.003), sampleRate: 16000).isEmpty)
    }

    func testFindsLoudSectionInQuietNoise() {
        let audio = noise(seconds: 1, amplitude: 0.002) + tone(seconds: 1, amplitude: 0.3) + noise(seconds: 1, amplitude: 0.002)
        let segs = EnergyVAD().speechSegments(in: audio, sampleRate: 16000)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 1.0, accuracy: 0.06)
        XCTAssertEqual(segs[0].end, 2.0, accuracy: 0.06)
    }
}

final class TextPostProcessorTests: XCTestCase {
    func testWhitespaceAndTags() {
        XCTAssertEqual(TextPostProcessor.normalizeWhitespace("  hello   [BLANK_AUDIO]  world \n"), "hello world")
        XCTAssertEqual(TextPostProcessor.normalizeWhitespace("(music) ok then"), "ok then")
    }

    func testPhantomOnlyOnShortClips() {
        let c = AppConfig()
        XCTAssertEqual(TextPostProcessor.process("Thank you.", speechSeconds: 0.6, config: c).text, "")
        XCTAssertNotNil(TextPostProcessor.process("Thank you.", speechSeconds: 0.6, config: c).discardedReason)
        XCTAssertEqual(TextPostProcessor.process("Thank you.", speechSeconds: 3, config: c).text, "Thank you.")
        XCTAssertEqual(TextPostProcessor.process("Thank you for the fix.", speechSeconds: 0.8, config: c).text, "Thank you for the fix.")
    }

    func testEmpty() {
        XCTAssertEqual(TextPostProcessor.process("  ", speechSeconds: 2, config: AppConfig()).discardedReason, "empty transcript")
    }
}

final class ConfigTests: XCTestCase {
    func testPartialFileUsesDefaults() throws {
        let json = #"{"engine": {"kind": "apple"}, "rawHotkey": {"key": "rightControl", "behavior": "toggle"}}"#
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.engine.kind, .apple)
        XCTAssertEqual(c.engine.locale, "en-IN")
        XCTAssertEqual(c.rawHotkey, HotkeyConfig(key: .rightControl, behavior: .toggle))
        XCTAssertEqual(c.cleanHotkey.key, .rightCommand)
        XCTAssertTrue(c.vad.enabled)
    }

    func testRoundTripAndValidation() throws {
        var c = AppConfig()
        c.vocabulary = ["Ollama", "SpeechAnalyzer"]
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded, c)
        XCTAssertTrue(c.validationErrors().isEmpty)
        c.cleanHotkey.key = .rightOption
        XCTAssertFalse(c.validationErrors().isEmpty)
    }

    func testEngineKindRawValue() throws {
        let c = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"kind":"apple-dictation"}"#.utf8))
        XCTAssertEqual(c.kind, .appleDictation)
    }
}

final class WAVTests: XCTestCase {
    func testRoundTrip() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        let (decoded, rate) = try WAV.decode(WAV.encode(samples: samples, sampleRate: 16000))
        XCTAssertEqual(rate, 16000)
        XCTAssertEqual(decoded.count, samples.count)
        for (a, b) in zip(decoded, samples) { XCTAssertEqual(a, b, accuracy: 1.0 / 16000) }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try WAV.decode(Data("hello world, not a wav".utf8)))
    }
}

final class LatencyAndHistoryTests: XCTestCase {
    func testStageDurations() {
        var t = LatencyTimer()
        t.mark("keyUp", at: 10.0)
        t.mark("vadDone", at: 10.01)
        t.mark("sttDone", at: 10.41)
        let d = t.stageDurationsMS()
        XCTAssertEqual(d["vadDone"]!, 10, accuracy: 0.2)
        XCTAssertEqual(d["sttDone"]!, 400, accuracy: 0.2)
        XCTAssertEqual(d["total_from_keyUp"]!, 410, accuracy: 0.2)
        XCTAssertEqual(t.ms(from: "keyUp", to: "sttDone")!, 410, accuracy: 0.2)
    }

    func testHistoryAppendAndRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = HistoryLog(url: dir.appendingPathComponent("history.jsonl"))
        let r = HistoryRecord(
            mode: .raw, engine: "whisper", rawText: "hello", finalText: "hello",
            audioSeconds: 1.2, speechSeconds: 0.9, latencyMS: ["sttDone": 300])
        try log.append(r)
        try log.append(r)
        let all = try HistoryLog.readAll(from: log.url)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].rawText, "hello")
        try? FileManager.default.removeItem(at: dir)
    }
}

final class LevelMeterTests: XCTestCase {
    func testMapping() {
        XCTAssertEqual(LevelMeter.normalized(rms: 0), 0)
        XCTAssertEqual(LevelMeter.normalized(rms: .nan), 0)
        XCTAssertEqual(LevelMeter.normalized(rms: 1e-4), 0)          // -80 dB
        XCTAssertEqual(LevelMeter.normalized(rms: 1), 1)              // 0 dB
        XCTAssertEqual(LevelMeter.normalized(rms: 0.01), 0.25, accuracy: 0.01)    // -40 dB
        XCTAssertEqual(LevelMeter.normalized(rms: 0.0316), 0.5, accuracy: 0.01)   // -30 dB, midpoint
        XCTAssertGreaterThan(LevelMeter.normalized(rms: 0.05), LevelMeter.normalized(rms: 0.01))
    }

    func testPushKeepsWindow() {
        var levels: [Float] = []
        for i in 0..<10 { LevelMeter.push(Float(i), into: &levels, count: 4) }
        XCTAssertEqual(levels, [6, 7, 8, 9])
    }
}

final class Stage2ConfigTests: XCTestCase {
    func testPasteDefaults() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(c.autoPaste)
        XCTAssertTrue(c.showOverlay)
        XCTAssertEqual(c.pasteRestoreDelaySeconds, 0.35)
        XCTAssertEqual(c.engine.whisperBeamSize, 5)
    }

    func testRestoreDelayValidated() {
        var c = AppConfig()
        c.pasteRestoreDelaySeconds = 0.01
        XCTAssertFalse(c.validationErrors().isEmpty)
    }

    func testOldHistoryLinesStillDecode() throws {
        // Stage-1 records have no "pasted" field.
        let line = #"{"audioSeconds":1,"engine":"w","finalText":"hi","latencyMS":{},"mode":"raw","rawText":"hi","speechSeconds":1,"timestamp":"2026-11-18T10:00:00Z","usedFallback":false}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let r = try d.decode(HistoryRecord.self, from: Data(line.utf8))
        XCTAssertNil(r.pasted)
    }
}
