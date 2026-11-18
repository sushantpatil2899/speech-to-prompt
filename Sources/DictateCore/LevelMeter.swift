import Foundation

/// Maps microphone RMS to a 0…1 bar height for the overlay's waveform.
public enum LevelMeter {
    /// Levels at or below this (dBFS) draw as an empty bar.
    public static let floorDB: Float = -50
    /// Levels at or above this draw as a full bar.
    public static let ceilingDB: Float = -10

    public static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let x = (db - floorDB) / (ceilingDB - floorDB)
        return min(1, max(0, x))
    }

    /// Appends `value`, keeping the most recent `count` values (oldest first).
    public static func push(_ value: Float, into levels: inout [Float], count: Int) {
        levels.append(value)
        if levels.count > count { levels.removeFirst(levels.count - count) }
    }
}
