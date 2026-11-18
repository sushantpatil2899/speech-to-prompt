import Foundation

/// Minimal WAV reading and writing for mono 16-bit PCM, the format used for recordings
/// and eval clips. (Other formats are read on macOS through AVAudioFile.)
public enum WAV {
    public enum Error: Swift.Error, CustomStringConvertible {
        case notWAV
        case unsupported(String)

        public var description: String {
            switch self {
            case .notWAV: return "not a RIFF/WAVE file"
            case .unsupported(let s): return "unsupported WAV: \(s)"
            }
        }
    }

    /// Encodes Float samples in [-1, 1] as 16-bit PCM mono.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let dataBytes = samples.count * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                              // PCM
        u16(1)                              // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))         // byte rate
        u16(2)                              // block align
        u16(16)                             // bits per sample
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        data.reserveCapacity(data.count + dataBytes)
        for s in samples {
            let clipped = max(-1, min(1, s))
            u16(UInt16(bitPattern: Int16((clipped * 32767).rounded())))
        }
        return data
    }

    public static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    /// Decodes 16-bit PCM or 32-bit float WAV. Multi-channel audio is averaged to mono.
    /// No resampling: returns the file's own sample rate.
    public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int) {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o+1]) << 8 | UInt32(bytes[o+2]) << 16 | UInt32(bytes[o+3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o+1]) << 8 }
        guard bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { throw Error.notWAV }

        var offset = 12
        var format: UInt16 = 0, channels = 1, rate = 0, bits = 0
        var pcm: ArraySlice<UInt8>? = nil
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(u32(offset + 4))
            let body = offset + 8
            let end = min(bytes.count, body + size)
            if id == "fmt " && size >= 16 {
                format = u16(body)
                channels = Int(u16(body + 2))
                rate = Int(u32(body + 4))
                bits = Int(u16(body + 14))
                if format == 0xFFFE && size >= 26 { format = u16(body + 24) } // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                pcm = bytes[body..<end]
            }
            offset = body + size + (size & 1)
        }
        guard let raw = pcm, rate > 0, channels > 0 else { throw Error.unsupported("missing fmt or data chunk") }

        var interleaved: [Float] = []
        let base = raw.startIndex
        switch (format, bits) {
        case (1, 16):
            let n = raw.count / 2
            interleaved.reserveCapacity(n)
            for i in 0..<n {
                let v = Int16(bitPattern: UInt16(raw[base + 2*i]) | UInt16(raw[base + 2*i + 1]) << 8)
                interleaved.append(Float(v) / 32768)
            }
        case (3, 32):
            let n = raw.count / 4
            interleaved.reserveCapacity(n)
            for i in 0..<n {
                let o = base + 4*i
                let b = UInt32(raw[o]) | UInt32(raw[o+1]) << 8 | UInt32(raw[o+2]) << 16 | UInt32(raw[o+3]) << 24
                interleaved.append(Float(bitPattern: b))
            }
        default:
            throw Error.unsupported("format \(format), \(bits) bits")
        }

        if channels == 1 { return (interleaved, rate) }
        let frames = interleaved.count / channels
        var mono = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += interleaved[f * channels + c] }
            mono[f] = sum / Float(channels)
        }
        return (mono, rate)
    }

    public static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Int) {
        try decode(Data(contentsOf: url))
    }
}
