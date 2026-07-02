import os
import Foundation

/// Logging that goes to BOTH the unified log (`log stream`) and a plain-text
/// file you can open and read directly:
///
///     ~/Library/Logs/SoundSplitter/soundsplitter.log
///
/// This is what lets us diagnose freezes/crashes after the fact — the
/// watchdog and crash handlers (see Diagnostics.swift) write here too.
enum Log {
    private static let logger = Logger(subsystem: "com.soundsplitter.app", category: "audio")

    /// Absolute path to the on-disk log file.
    static let fileURL: URL = {
        let base = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/SoundSplitter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("soundsplitter.log")
    }()

    private static let queue = DispatchQueue(label: "com.soundsplitter.log")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String)  { emit("INFO",  message); logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { emit("ERROR", message); logger.error("\(message, privacy: .public)") }
    static func debug(_ message: String) { emit("DEBUG", message); logger.debug("\(message, privacy: .public)") }

    /// Append a line to the log file. Also used directly by crash handlers,
    /// so it must not allocate heavily or depend on the main thread.
    static func emit(_ level: String, _ message: String) {
        let line = "\(dateFormatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async { append(line) }
    }

    /// Synchronous append — safe to call from a signal/exception handler.
    static func appendSync(_ line: String) { append(line) }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
