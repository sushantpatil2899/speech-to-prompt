import AVFoundation
import DictateCore

public enum AudioError: Error, CustomStringConvertible {
    case noInputDevice
    case microphoneDenied
    case formatUnavailable
    case conversionFailed(String)

    public var description: String {
        switch self {
        case .noInputDevice: return "No audio input device is available."
        case .microphoneDenied: return "Microphone access is denied. Allow it in System Settings → Privacy & Security → Microphone."
        case .formatUnavailable: return "Could not create the audio format."
        case .conversionFailed(let s): return "Audio conversion failed: \(s)"
        }
    }
}

/// 16 kHz mono Float32, the format every engine receives.
public enum PCM {
    public static let sampleRate: Double = 16000

    public static let format: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Wraps samples in an AVAudioPCMBuffer (16 kHz mono Float32).
    public static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let ch = buf.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { ch.update(from: base, count: samples.count) }
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        return buf
    }

    public static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }

    /// Converts a whole buffer in one go (input is treated as the complete stream).
    public static func convert(_ input: AVAudioPCMBuffer, to outFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format == outFormat { return input }
        guard let converter = AVAudioConverter(from: input.format, to: outFormat) else {
            throw AudioError.conversionFailed("no converter from \(input.format) to \(outFormat)")
        }
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 4096)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw AudioError.formatUnavailable
        }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if given {
                outStatus.pointee = .endOfStream
                return nil
            }
            given = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw AudioError.conversionFailed(error?.localizedDescription ?? "unknown error")
        }
        return out
    }
}

/// Stateful converter for a live stream of buffers (keeps resampler state between calls).
public final class StreamingConverter {
    private let converter: AVAudioConverter
    public let outputFormat: AVAudioFormat

    public init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: output) else { return nil }
        converter = c
        outputFormat = output
    }

    public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if given {
                outStatus.pointee = .noDataNow
                return nil
            }
            given = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

/// Loads any audio file AVFoundation can read and returns 16 kHz mono Float32 samples.
public enum AudioFileLoader {
    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw AudioError.formatUnavailable
        }
        try file.read(into: buf)
        return PCM.samples(of: try PCM.convert(buf, to: PCM.format))
    }
}
