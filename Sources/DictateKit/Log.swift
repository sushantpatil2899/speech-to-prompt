import Foundation
import os

/// Unified logging. Watch it live with:
///   log stream --level info --predicate 'subsystem == "local.SpeechToPrompt"'
public enum Log {
    public static let subsystem = "local.SpeechToPrompt"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let stt = Logger(subsystem: subsystem, category: "stt")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
