import CoreGraphics
import Foundation
import LightShotCore

extension Notification.Name {
    /// Posted on the main actor after a screenshot has been written to the
    /// history store. The notification's `object` is the recorded
    /// `HistoryEntry`, so an observer can add it to a cache without another
    /// asynchronous store read.
    static let lightShotHistoryDidChange = Notification.Name("lightShotHistoryDidChange")
}

/// Records history entries for images the user just copied or saved.
///
/// Centralizes the "Keep history" check so every capture path honors the user
/// setting and no call site has to remember to gate the asynchronous write.
@MainActor
enum HistoryRecorder {
    /// Launches an asynchronous history record when history is enabled. When it
    /// is disabled this returns without scheduling any work.
    static func record(
        _ image: CGImage,
        source: CaptureSource,
        settings: AppSettings,
        history: HistoryStore
    ) {
        guard settings.historyEnabled else { return }
        let imageData = ImageData(image)
        Task {
            guard let entry = try? await history.record(image: imageData, source: source) else { return }
            // The write has completed, so the Recent menu can already show the
            // new entry when the user opens it next.
            NotificationCenter.default.post(name: .lightShotHistoryDidChange, object: entry)
        }
    }
}
