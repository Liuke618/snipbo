import CoreGraphics
import Foundation
import LightShotCore
import os

extension Notification.Name {
    /// Posted on the main actor after a screenshot has been written to the
    /// history store. The notification's `object` is the recorded
    /// `HistoryEntry`, so an observer can add it to a cache without another
    /// asynchronous store read.
    static let lightShotHistoryDidChange = Notification.Name("lightShotHistoryDidChange")

    /// Posted on the main actor when a history write or limit update fails.
    /// The notification's `object` is a user-presentable failure description;
    /// observers show it without blocking the copy/save that already succeeded.
    static let lightShotHistoryWriteFailed = Notification.Name("lightShotHistoryWriteFailed")
}

/// Records history entries for delivered captures.
///
/// Centralizes the "Keep history" check so every capture path honors the user
/// setting and no call site has to remember to gate the asynchronous write.
@MainActor
enum HistoryRecorder {
    static let logger = Logger(subsystem: "local.lightshot.app", category: "History")

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
            do {
                let entry = try await history.record(image: imageData, source: source)
                // The write has completed, so the Recent menu can already show
                // the new entry when the user opens it next.
                NotificationCenter.default.post(name: .lightShotHistoryDidChange, object: entry)
            } catch {
                let message = error.localizedDescription
                logger.error(
                    "Failed to record a history entry: \(message, privacy: .public)"
                )
                NotificationCenter.default.post(
                    name: .lightShotHistoryWriteFailed,
                    object: message
                )
            }
        }
    }
}
