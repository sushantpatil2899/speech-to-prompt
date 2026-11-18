import AVFoundation
import DictateCore

/// Records from the default input device and delivers 16 kHz mono Float32.
///
/// The engine is started on key-down and stopped on key-up, so the orange microphone
/// indicator only shows while you dictate.
public final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var converter: StreamingConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var configObserver: NSObjectProtocol?
    public private(set) var isRunning = false

    /// Called on the audio thread with the RMS level (0…1) of each chunk.
    public var onLevel: ((Float) -> Void)?
    /// Called on the audio thread with each converted 16 kHz mono chunk (for streaming engines).
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    public init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            // The input device changed (headset plugged in, AirPods connected...).
            // Rebuild the engine so the next recording uses the new device and format.
            guard let self, !self.isRunning else { return }
            Log.audio.info("Audio configuration changed; rebuilding engine")
            self.engine = AVAudioEngine()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    public static var microphonePermission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() throws {
        guard !isRunning else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw AudioError.noInputDevice }
        guard let conv = StreamingConverter(from: inFormat, to: PCM.format) else { throw AudioError.formatUnavailable }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    /// Stops recording and returns everything captured since `start()`.
    @discardableResult
    public func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    /// Seconds captured so far.
    public var capturedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / PCM.sampleRate
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let out = converter?.convert(buffer), let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: ch, count: n)
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()

        if let onLevel {
            var sum: Float = 0
            for s in chunk { sum += s * s }
            onLevel((sum / Float(max(1, n))).squareRoot())
        }
        onBuffer?(out)
    }
}
