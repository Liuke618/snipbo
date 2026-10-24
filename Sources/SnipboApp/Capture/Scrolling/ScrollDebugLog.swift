import Foundation
import os

/// File-based diagnostics for the scrolling-capture pipeline. The unified log
/// drops .info entries, and the real SCStream path cannot be exercised from a
/// harness, so the scrolling path appends its decisions to a temp file that a
/// debugging session can read directly.
enum ScrollDebugLog {
    private static let lock = NSLock()
    private static let url = URL(fileURLWithPath: "/tmp/snipbo-scroll-debug.log")
    private static let logger = Logger(subsystem: "local.snipbo.app", category: "Scroll")

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        lock.lock()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        lock.unlock()
    }
}
