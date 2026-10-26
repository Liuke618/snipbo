import os

/// Diagnostics for the scrolling-capture pipeline. These go to the unified
/// log instead of a fixed temp file: the old `/tmp/snipbo-scroll-debug.log`
/// grew without bound and could be redirected through a symlink.
enum ScrollDebugLog {
    private static let logger = Logger(subsystem: "local.snipbo.app", category: "Scroll")

    static func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
