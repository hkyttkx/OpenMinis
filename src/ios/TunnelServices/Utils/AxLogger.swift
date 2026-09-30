import Foundation

public enum AxLogLevel: String {
    case Debug
    case Info
    case Warn
    case Error
}

public enum AxLogger {
    public static func openLogging(_ directory: URL, date: Date, debug: Bool) {
        // Phase 2: keep lightweight logging and ensure directory exists.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        if debug {
            NSLog("[AxLogger][Debug] log directory: \(directory.path)")
        }
    }

    public static func log(_ message: String, level: AxLogLevel = .Info) {
        NSLog("[AxLogger][\(level.rawValue)] \(message)")
    }
}
