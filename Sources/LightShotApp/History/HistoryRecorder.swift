import CoreGraphics
import LightShotCore

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
        Task { try? await history.record(image: imageData, source: source) }
    }
}
