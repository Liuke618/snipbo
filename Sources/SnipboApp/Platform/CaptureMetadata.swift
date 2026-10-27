import Foundation
import SnipboCore

/// Context used to expand file-name tokens such as {source}, {app}, and
/// {window}. Capture mode, app name, and window title are snapshotted at
/// capture time so a later focus change cannot rename the file.
struct CaptureMetadata: Equatable, Sendable {
    var source: CaptureSource
    var appName: String?
    var windowTitle: String?
}
