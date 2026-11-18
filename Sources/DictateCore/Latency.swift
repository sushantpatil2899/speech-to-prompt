import Foundation

/// Records named timestamps for one dictation, so each stage's duration can be reported.
///
/// Stage names used by the app (in order):
///   keyDown, micStarted, keyUp, audioStopped, vadDone, sttDone, llmDone, pasted
/// `keyUp` is the reference point for the latency targets.
public struct LatencyTimer: Sendable {
    public private(set) var marks: [(name: String, time: Double)] = []

    public init() {}

    /// Monotonic time in seconds.
    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    public mutating func mark(_ name: String, at time: Double = LatencyTimer.now()) {
        marks.append((name, time))
    }

    public func time(of name: String) -> Double? {
        marks.last(where: { $0.name == name })?.time
    }

    /// Milliseconds between two marks, if both exist.
    public func ms(from a: String, to b: String) -> Double? {
        guard let ta = time(of: a), let tb = time(of: b) else { return nil }
        return (tb - ta) * 1000
    }

    /// Duration of each stage (time since the previous mark), in milliseconds, keyed by the
    /// stage's end mark. Also includes "total_from_keyUp" when keyUp exists.
    public func stageDurationsMS() -> [String: Double] {
        var result: [String: Double] = [:]
        for i in 1..<max(1, marks.count) {
            result[marks[i].name] = ((marks[i].time - marks[i - 1].time) * 1000).rounded(toPlaces: 1)
        }
        if let up = time(of: "keyUp"), let last = marks.last, last.time >= up {
            result["total_from_keyUp"] = ((last.time - up) * 1000).rounded(toPlaces: 1)
        }
        return result
    }

    /// One-line summary such as "keyUp→audioStopped 12 ms · vad 8 ms · stt 412 ms · total 432 ms".
    public func summary() -> String {
        guard marks.count > 1 else { return "" }
        var parts: [String] = []
        for i in 1..<marks.count {
            let ms = (marks[i].time - marks[i - 1].time) * 1000
            parts.append("\(marks[i - 1].name)→\(marks[i].name) \(Int(ms.rounded())) ms")
        }
        if let up = time(of: "keyUp"), let last = marks.last, last.time >= up {
            parts.append("total since keyUp \(Int(((last.time - up) * 1000).rounded())) ms")
        }
        return parts.joined(separator: " · ")
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}
