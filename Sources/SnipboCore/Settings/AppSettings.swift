import Foundation

public enum ImageFormat: String, Codable, Sendable {
    case png
    case jpeg
    case heic
    case avif

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .avif: return "avif"
        }
    }

    public var isLossy: Bool { self != .png }
}

public enum WatermarkPosition: String, Codable, Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, center
}

public enum BeautifyBackground: String, Codable, Sendable, CaseIterable {
    case light, dark, blue, transparent
}

public enum AppAppearance: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

public enum RecordingFormat: String, Codable, Sendable, CaseIterable {
    case mp4, gif

    public var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .gif: return "gif"
        }
    }
}

public enum SelectionAspectRatio: String, Codable, Sendable, CaseIterable {
    case free, square, fourThree, sixteenNine

    public var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        }
    }
}

/// What happens to a capture when the editor is not opened. A capture must
/// always have at least one destination; normalization forces copy when every
/// action is off.
public struct CaptureActions: Codable, Equatable, Sendable {
    public var openEditor: Bool
    public var copy: Bool
    public var save: Bool
    public var pin: Bool

    public init(
        openEditor: Bool = false,
        copy: Bool = false,
        save: Bool = false,
        pin: Bool = false
    ) {
        self.openEditor = openEditor
        self.copy = copy
        self.save = save
        self.pin = pin
    }

    public var isEmpty: Bool { !openEditor && !copy && !save && !pin }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Languages offered in Settings and passed to Vision. Vision identifies
    /// these with BCP-47-style identifiers.
    public static let supportedOCRLanguages = ["zh-Hans", "en-US"]
    public static let defaultOCRLanguages = ["zh-Hans", "en-US"]

    public var hotkey: Hotkey
    public var saveDirectory: String
    public var format: ImageFormat
    public var jpegQuality: Double
    public var openEditorAfterCapture: Bool
    public var historyEnabled: Bool
    public var historyMaxItems: Int
    public var historyMaxBytes: Int64
    /// Runs on-device OCR when a capture is recorded so history can be
    /// searched by its text.
    public var historySearchEnabled: Bool
    public var captureCursor: Bool
    /// Countdown used by the timed capture menu entries, in seconds.
    public var captureDelaySeconds: Int
    /// Ordered languages for `VNRecognizeTextRequest`.
    public var ocrLanguages: [String]
    /// Height cap in pixels for a stitched scrolling capture.
    public var scrollMaxHeight: Int
    /// Applied when the editor does not open: copy the capture to the
    /// clipboard immediately.
    public var afterCaptureCopy: Bool
    /// Applied when the editor does not open: save the capture to the save
    /// directory immediately.
    public var afterCaptureSave: Bool
    /// Keeps the app registered as a macOS login item.
    public var launchAtLogin: Bool
    /// Exports retina captures at 1x by halving the pixel size.
    public var retinaDownscale: Bool
    /// Joins OCR text blocks into one paragraph without line breaks.
    public var ocrRemoveLineBreaks: Bool
    /// Frame rate target for scrolling capture, in frames per second.
    public var scrollCaptureFPS: Int
    /// Copies the rendered image before an editor Esc closes the window.
    public var copyOnEditorEscape: Bool
    /// Saves the rendered image to the save directory before an editor Esc
    /// closes the window (Shottr's "Action when hiding with Esc").
    public var saveOnEditorEscape: Bool
    /// Per-mode global shortcuts, keyed by capture mode. Modes without an
    /// entry fall back to `hotkey` for the region mode and have no chord
    /// otherwise.
    public var modeHotkeys: [String: Hotkey]
    /// UI language for menus, settings, and dialogs.
    public var uiLanguage: AppLanguage
    /// App-wide light/dark override; system follows macOS.
    public var appearance: AppAppearance
    public var recordingFormat: RecordingFormat
    public var recordingFPS: Int
    public var recordingMaxSeconds: Int
    /// GIF frames are downscaled to this width before encoding.
    public var recordingGIFMaxWidth: Int
    /// Hides the menu bar icon. Settings can still be reopened from
    /// Spotlight or Finder, which activates the app and shows Settings.
    public var hideMenuBarIcon: Bool
    /// Removes stored screenshots when the app quits.
    public var clearHistoryOnQuit: Bool
    /// Per-mode capture actions. Modes without an entry use the legacy
    /// `openEditorAfterCapture` / `afterCaptureCopy` / `afterCaptureSave`
    /// profile.
    public var modeActions: [String: CaptureActions]
    /// Target maximum encoded size in KB. Zero keeps the quality setting.
    public var targetFileSizeKB: Int
    /// Supports {date}, {time}, {datetime}, {source}, {app}, {window}, {n}.
    public var fileNameTemplate: String
    public var watermarkEnabled: Bool
    public var watermarkText: String
    public var watermarkPosition: WatermarkPosition
    public var watermarkOpacity: Double
    public var beautifyEnabled: Bool
    public var beautifyPadding: Int
    public var beautifyCornerRadius: Int
    public var beautifyBackground: BeautifyBackground
    public var beautifyShadow: Bool
    public var selectionSnapToWindows: Bool
    public var selectionAspectRatio: SelectionAspectRatio
    /// Zero means the drag decides the size. Both must be non-zero to lock a
    /// fixed selection size.
    public var selectionFixedWidth: Int
    public var selectionFixedHeight: Int

    /// Capture modes that can carry their own global shortcut, in the order
    /// used to resolve chord conflicts.
    public static let hotkeyModeIDs = [
        "region", "window", "screen", "allScreens",
        "timedRegion", "timedScreen", "timedWindow", "lastRegion", "scrolling",
    ]

    /// Stable Carbon hotkey identifiers, one per mode.
    public static let hotkeyModeIDsToCarbonID: [String: UInt32] = [
        "region": 1,
        "window": 2,
        "screen": 3,
        "allScreens": 4,
        "timedRegion": 5,
        "timedScreen": 6,
        "timedWindow": 9,
        "lastRegion": 7,
        "scrolling": 8,
    ]

    /// The effective chord for a mode: the explicit entry, or the base hotkey
    /// for the region mode.
    public func hotkey(for mode: String) -> Hotkey? {
        if let configured = modeHotkeys[mode] { return configured }
        return mode == "region" ? hotkey : nil
    }

    private enum CodingKeys: String, CodingKey {
        case hotkey
        case saveDirectory
        case format
        case jpegQuality
        case openEditorAfterCapture
        case historyEnabled
        case historyMaxItems
        case historyMaxBytes
        case historySearchEnabled
        case captureCursor
        case captureDelaySeconds
        case ocrLanguages
        case scrollMaxHeight
        case afterCaptureCopy
        case afterCaptureSave
        case launchAtLogin
        case retinaDownscale
        case ocrRemoveLineBreaks
        case scrollCaptureFPS
        case copyOnEditorEscape
        case saveOnEditorEscape
        case modeHotkeys
        case uiLanguage
        case appearance
        case recordingFormat
        case recordingFPS
        case recordingMaxSeconds
        case recordingGIFMaxWidth
        case hideMenuBarIcon
        case clearHistoryOnQuit
        case modeActions
        case targetFileSizeKB
        case fileNameTemplate
        case watermarkEnabled
        case watermarkText
        case watermarkPosition
        case watermarkOpacity
        case beautifyEnabled
        case beautifyPadding
        case beautifyCornerRadius
        case beautifyBackground
        case beautifyShadow
        case selectionSnapToWindows
        case selectionAspectRatio
        case selectionFixedWidth
        case selectionFixedHeight
    }

    public init(
        hotkey: Hotkey,
        saveDirectory: String,
        format: ImageFormat,
        jpegQuality: Double,
        openEditorAfterCapture: Bool,
        historyEnabled: Bool,
        historyMaxItems: Int,
        historyMaxBytes: Int64,
        historySearchEnabled: Bool = true,
        captureCursor: Bool,
        captureDelaySeconds: Int = 3,
        ocrLanguages: [String] = AppSettings.defaultOCRLanguages,
        scrollMaxHeight: Int = 20_000,
        afterCaptureCopy: Bool = true,
        afterCaptureSave: Bool = false,
        launchAtLogin: Bool = false,
        retinaDownscale: Bool = false,
        ocrRemoveLineBreaks: Bool = false,
        scrollCaptureFPS: Int = 10,
        copyOnEditorEscape: Bool = false,
        saveOnEditorEscape: Bool = false,
        modeHotkeys: [String: Hotkey] = [:],
        uiLanguage: AppLanguage = .system,
        appearance: AppAppearance = .system,
        recordingFormat: RecordingFormat = .mp4,
        recordingFPS: Int = 30,
        recordingMaxSeconds: Int = 120,
        recordingGIFMaxWidth: Int = 800,
        hideMenuBarIcon: Bool = false,
        clearHistoryOnQuit: Bool = false,
        modeActions: [String: CaptureActions] = [:],
        targetFileSizeKB: Int = 0,
        fileNameTemplate: String = "Snipbo-{datetime}",
        watermarkEnabled: Bool = false,
        watermarkText: String = "Snipbo",
        watermarkPosition: WatermarkPosition = .bottomRight,
        watermarkOpacity: Double = 0.75,
        beautifyEnabled: Bool = false,
        beautifyPadding: Int = 32,
        beautifyCornerRadius: Int = 12,
        beautifyBackground: BeautifyBackground = .light,
        beautifyShadow: Bool = true,
        selectionSnapToWindows: Bool = true,
        selectionAspectRatio: SelectionAspectRatio = .free,
        selectionFixedWidth: Int = 0,
        selectionFixedHeight: Int = 0
    ) {
        self.hotkey = hotkey
        self.saveDirectory = saveDirectory
        self.format = format
        self.jpegQuality = jpegQuality
        self.openEditorAfterCapture = openEditorAfterCapture
        self.historyEnabled = historyEnabled
        self.historyMaxItems = historyMaxItems
        self.historyMaxBytes = historyMaxBytes
        self.historySearchEnabled = historySearchEnabled
        self.captureCursor = captureCursor
        self.captureDelaySeconds = captureDelaySeconds
        self.ocrLanguages = ocrLanguages
        self.scrollMaxHeight = scrollMaxHeight
        self.afterCaptureCopy = afterCaptureCopy
        self.afterCaptureSave = afterCaptureSave
        self.launchAtLogin = launchAtLogin
        self.retinaDownscale = retinaDownscale
        self.ocrRemoveLineBreaks = ocrRemoveLineBreaks
        self.scrollCaptureFPS = scrollCaptureFPS
        self.copyOnEditorEscape = copyOnEditorEscape
        self.saveOnEditorEscape = saveOnEditorEscape
        self.modeHotkeys = modeHotkeys
        self.uiLanguage = uiLanguage
        self.appearance = appearance
        self.recordingFormat = recordingFormat
        self.recordingFPS = recordingFPS
        self.recordingMaxSeconds = recordingMaxSeconds
        self.recordingGIFMaxWidth = recordingGIFMaxWidth
        self.hideMenuBarIcon = hideMenuBarIcon
        self.clearHistoryOnQuit = clearHistoryOnQuit
        self.modeActions = modeActions
        self.targetFileSizeKB = targetFileSizeKB
        self.fileNameTemplate = fileNameTemplate
        self.watermarkEnabled = watermarkEnabled
        self.watermarkText = watermarkText
        self.watermarkPosition = watermarkPosition
        self.watermarkOpacity = watermarkOpacity
        self.beautifyEnabled = beautifyEnabled
        self.beautifyPadding = beautifyPadding
        self.beautifyCornerRadius = beautifyCornerRadius
        self.beautifyBackground = beautifyBackground
        self.beautifyShadow = beautifyShadow
        self.selectionSnapToWindows = selectionSnapToWindows
        self.selectionAspectRatio = selectionAspectRatio
        self.selectionFixedWidth = selectionFixedWidth
        self.selectionFixedHeight = selectionFixedHeight
    }

    /// Decodes missing fields defensively so payloads written by earlier
    /// versions keep working after new fields are introduced.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? fallback.hotkey
        saveDirectory = try container.decodeIfPresent(String.self, forKey: .saveDirectory) ?? fallback.saveDirectory
        format = try container.decodeIfPresent(ImageFormat.self, forKey: .format) ?? fallback.format
        jpegQuality = try container.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? fallback.jpegQuality
        openEditorAfterCapture = try container.decodeIfPresent(Bool.self, forKey: .openEditorAfterCapture) ?? fallback.openEditorAfterCapture
        historyEnabled = try container.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? fallback.historyEnabled
        historyMaxItems = try container.decodeIfPresent(Int.self, forKey: .historyMaxItems) ?? fallback.historyMaxItems
        historyMaxBytes = try container.decodeIfPresent(Int64.self, forKey: .historyMaxBytes) ?? fallback.historyMaxBytes
        historySearchEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .historySearchEnabled
        ) ?? fallback.historySearchEnabled
        captureCursor = try container.decodeIfPresent(Bool.self, forKey: .captureCursor) ?? fallback.captureCursor
        captureDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .captureDelaySeconds) ?? fallback.captureDelaySeconds
        ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? fallback.ocrLanguages
        scrollMaxHeight = try container.decodeIfPresent(Int.self, forKey: .scrollMaxHeight)
            ?? fallback.scrollMaxHeight
        afterCaptureCopy = try container.decodeIfPresent(Bool.self, forKey: .afterCaptureCopy)
            ?? fallback.afterCaptureCopy
        afterCaptureSave = try container.decodeIfPresent(Bool.self, forKey: .afterCaptureSave)
            ?? fallback.afterCaptureSave
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? fallback.launchAtLogin
        retinaDownscale = try container.decodeIfPresent(Bool.self, forKey: .retinaDownscale)
            ?? fallback.retinaDownscale
        ocrRemoveLineBreaks = try container.decodeIfPresent(Bool.self, forKey: .ocrRemoveLineBreaks)
            ?? fallback.ocrRemoveLineBreaks
        scrollCaptureFPS = try container.decodeIfPresent(Int.self, forKey: .scrollCaptureFPS)
            ?? fallback.scrollCaptureFPS
        copyOnEditorEscape = try container.decodeIfPresent(Bool.self, forKey: .copyOnEditorEscape)
            ?? fallback.copyOnEditorEscape
        saveOnEditorEscape = try container.decodeIfPresent(Bool.self, forKey: .saveOnEditorEscape)
            ?? fallback.saveOnEditorEscape
        modeHotkeys = try container.decodeIfPresent([String: Hotkey].self, forKey: .modeHotkeys)
            ?? fallback.modeHotkeys
        uiLanguage = try container.decodeIfPresent(AppLanguage.self, forKey: .uiLanguage)
            ?? fallback.uiLanguage
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance)
            ?? fallback.appearance
        recordingFormat = try container.decodeIfPresent(RecordingFormat.self, forKey: .recordingFormat)
            ?? fallback.recordingFormat
        recordingFPS = try container.decodeIfPresent(Int.self, forKey: .recordingFPS)
            ?? fallback.recordingFPS
        recordingMaxSeconds = try container.decodeIfPresent(Int.self, forKey: .recordingMaxSeconds)
            ?? fallback.recordingMaxSeconds
        recordingGIFMaxWidth = try container.decodeIfPresent(Int.self, forKey: .recordingGIFMaxWidth)
            ?? fallback.recordingGIFMaxWidth
        hideMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .hideMenuBarIcon)
            ?? fallback.hideMenuBarIcon
        clearHistoryOnQuit = try container.decodeIfPresent(Bool.self, forKey: .clearHistoryOnQuit)
            ?? fallback.clearHistoryOnQuit
        modeActions = try container.decodeIfPresent(
            [String: CaptureActions].self,
            forKey: .modeActions
        ) ?? fallback.modeActions
        targetFileSizeKB = try container.decodeIfPresent(Int.self, forKey: .targetFileSizeKB)
            ?? fallback.targetFileSizeKB
        fileNameTemplate = try container.decodeIfPresent(String.self, forKey: .fileNameTemplate)
            ?? fallback.fileNameTemplate
        watermarkEnabled = try container.decodeIfPresent(Bool.self, forKey: .watermarkEnabled)
            ?? fallback.watermarkEnabled
        watermarkText = try container.decodeIfPresent(String.self, forKey: .watermarkText)
            ?? fallback.watermarkText
        watermarkPosition = try container.decodeIfPresent(WatermarkPosition.self, forKey: .watermarkPosition)
            ?? fallback.watermarkPosition
        watermarkOpacity = try container.decodeIfPresent(Double.self, forKey: .watermarkOpacity)
            ?? fallback.watermarkOpacity
        beautifyEnabled = try container.decodeIfPresent(Bool.self, forKey: .beautifyEnabled)
            ?? fallback.beautifyEnabled
        beautifyPadding = try container.decodeIfPresent(Int.self, forKey: .beautifyPadding)
            ?? fallback.beautifyPadding
        beautifyCornerRadius = try container.decodeIfPresent(Int.self, forKey: .beautifyCornerRadius)
            ?? fallback.beautifyCornerRadius
        beautifyBackground = try container.decodeIfPresent(BeautifyBackground.self, forKey: .beautifyBackground)
            ?? fallback.beautifyBackground
        beautifyShadow = try container.decodeIfPresent(Bool.self, forKey: .beautifyShadow)
            ?? fallback.beautifyShadow
        selectionSnapToWindows = try container.decodeIfPresent(
            Bool.self,
            forKey: .selectionSnapToWindows
        ) ?? fallback.selectionSnapToWindows
        selectionAspectRatio = try container.decodeIfPresent(
            SelectionAspectRatio.self,
            forKey: .selectionAspectRatio
        ) ?? fallback.selectionAspectRatio
        selectionFixedWidth = try container.decodeIfPresent(
            Int.self,
            forKey: .selectionFixedWidth
        ) ?? fallback.selectionFixedWidth
        selectionFixedHeight = try container.decodeIfPresent(
            Int.self,
            forKey: .selectionFixedHeight
        ) ?? fallback.selectionFixedHeight
    }

    public static let defaultSaveDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Snipbo", isDirectory: true)
        .path

    public static let `default` = AppSettings(
        hotkey: Hotkey(keyCode: 26, modifiers: [.command, .shift]),
        saveDirectory: defaultSaveDirectory,
        format: .png,
        jpegQuality: 0.9,
        openEditorAfterCapture: true,
        historyEnabled: true,
        historyMaxItems: 200,
        historyMaxBytes: 500 * 1024 * 1024,
        historySearchEnabled: true,
        captureCursor: false,
        captureDelaySeconds: 3,
        ocrLanguages: AppSettings.defaultOCRLanguages,
        scrollMaxHeight: 20_000,
        afterCaptureCopy: true,
        afterCaptureSave: false,
        launchAtLogin: false,
        retinaDownscale: false,
        ocrRemoveLineBreaks: false,
        copyOnEditorEscape: false,
        saveOnEditorEscape: false,
        modeHotkeys: [:],
        uiLanguage: .system,
        appearance: .system,
        recordingFormat: .mp4,
        recordingFPS: 30,
        recordingMaxSeconds: 120,
        recordingGIFMaxWidth: 800,
        hideMenuBarIcon: false,
        clearHistoryOnQuit: false,
        modeActions: [:],
        targetFileSizeKB: 0,
        fileNameTemplate: "Snipbo-{datetime}",
        watermarkEnabled: false,
        watermarkText: "Snipbo",
        watermarkPosition: .bottomRight,
        watermarkOpacity: 0.75,
        beautifyEnabled: false,
        beautifyPadding: 32,
        beautifyCornerRadius: 12,
        beautifyBackground: .light,
        beautifyShadow: true,
        selectionSnapToWindows: true,
        selectionAspectRatio: .free,
        selectionFixedWidth: 0,
        selectionFixedHeight: 0
    )

    /// Effective actions for a capture mode: an explicit per-mode override, or
    /// the legacy global profile. A capture can never end with no destination.
    public func actions(for mode: String) -> CaptureActions {
        if var override = modeActions[mode] {
            if override.isEmpty { override.copy = true }
            return override
        }
        var actions = CaptureActions(
            openEditor: openEditorAfterCapture,
            copy: afterCaptureCopy,
            save: afterCaptureSave
        )
        if actions.isEmpty { actions.copy = true }
        return actions
    }

    public func normalized() -> AppSettings {
        var copy = self
        if !copy.hotkey.isGlobalShortcut {
            copy.hotkey = Self.default.hotkey
        }
        copy.jpegQuality = min(1, max(0.1, jpegQuality))
        copy.historyMaxItems = min(1000, max(1, historyMaxItems))
        copy.historyMaxBytes = min(10 * 1024 * 1024 * 1024, max(10 * 1024 * 1024, historyMaxBytes))
        copy.captureDelaySeconds = min(30, max(0, captureDelaySeconds))
        copy.scrollMaxHeight = min(100_000, max(1_000, scrollMaxHeight))
        copy.scrollCaptureFPS = min(30, max(5, scrollCaptureFPS))
        // A direct capture (editor off) must never be silently discarded.
        if !copy.openEditorAfterCapture, !copy.afterCaptureCopy, !copy.afterCaptureSave {
            copy.afterCaptureCopy = true
        }
        // Drop unknown modes and chords that collide (the region fallback
        // occupies its chord first), so Carbon never registers one chord twice.
        var effective: [String: Hotkey] = [:]
        var used = Set<Hotkey>()
        for mode in Self.hotkeyModeIDs {
            let chord: Hotkey?
            if let configured = copy.modeHotkeys[mode] {
                chord = configured
            } else if mode == "region" {
                chord = copy.hotkey
            } else {
                chord = nil
            }
            guard let chord, chord.isGlobalShortcut, used.insert(chord).inserted else { continue }
            effective[mode] = chord
        }
        copy.modeHotkeys = copy.modeHotkeys.filter { effective[$0.key] == $0.value }
        if copy.saveDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.saveDirectory = Self.defaultSaveDirectory
        }
        var seen = Set<String>()
        copy.ocrLanguages = ocrLanguages.filter {
            Self.supportedOCRLanguages.contains($0) && seen.insert($0).inserted
        }
        copy.recordingFPS = min(30, max(5, copy.recordingFPS))
        copy.recordingMaxSeconds = min(600, max(5, copy.recordingMaxSeconds))
        copy.recordingGIFMaxWidth = min(1_920, max(240, copy.recordingGIFMaxWidth))
        copy.targetFileSizeKB = min(100_000, max(0, copy.targetFileSizeKB))
        let template = copy.fileNameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.fileNameTemplate = template.isEmpty ? "Snipbo-{datetime}" : template
        copy.watermarkOpacity = min(1, max(0.05, copy.watermarkOpacity))
        copy.beautifyPadding = min(200, max(0, copy.beautifyPadding))
        copy.beautifyCornerRadius = min(80, max(0, copy.beautifyCornerRadius))
        copy.selectionFixedWidth = min(20_000, max(0, copy.selectionFixedWidth))
        copy.selectionFixedHeight = min(20_000, max(0, copy.selectionFixedHeight))
        if copy.selectionFixedWidth == 0 || copy.selectionFixedHeight == 0 {
            copy.selectionFixedWidth = 0
            copy.selectionFixedHeight = 0
        }
        if copy.ocrLanguages.isEmpty {
            copy.ocrLanguages = Self.defaultOCRLanguages
        }
        var sanitizedActions: [String: CaptureActions] = [:]
        for (mode, actions) in copy.modeActions where Self.hotkeyModeIDs.contains(mode) {
            var fixed = actions
            if fixed.isEmpty { fixed.copy = true }
            sanitizedActions[mode] = fixed
        }
        copy.modeActions = sanitizedActions
        return copy
    }
}
