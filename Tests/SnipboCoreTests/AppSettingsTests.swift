import Foundation
import Testing
@testable import SnipboCore

@Suite("AppSettingsTests")
struct AppSettingsTests {
    @Test func testDefaults() {
        let settings = AppSettings.default
        #expect(settings.hotkey == Hotkey(keyCode: 26, modifiers: [.command, .shift]))
        #expect(settings.format == .png)
        #expect(settings.jpegQuality == 0.9)
        #expect(settings.openEditorAfterCapture)
        #expect(settings.historyEnabled)
        #expect(settings.historyMaxItems == 200)
        #expect(settings.historyMaxBytes == 500 * 1024 * 1024)
        #expect(!settings.captureCursor)
        #expect(settings.saveDirectory.hasSuffix("Pictures/Snipbo"))
        #expect(settings.captureDelaySeconds == 3)
        #expect(settings.ocrLanguages == ["zh-Hans", "en-US"])
    }

    @Test func testCodableRoundTrip() throws {
        let settings = AppSettings.default
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func testHiddenStatusItemsRoundTripAndLegacyFallback() throws {
        var settings = AppSettings.default
        settings.hiddenStatusItems = [.record, .pins]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.hiddenStatusItems == [.record, .pins])

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "hiddenStatusItems")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(migrated.hiddenStatusItems.isEmpty)
    }

    @Test func testLegacyPayloadWithoutPhaseTwoFieldsUsesDefaults() throws {
        let current = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(
            JSONSerialization.jsonObject(with: current) as? [String: Any]
        )
        object.removeValue(forKey: "captureDelaySeconds")
        object.removeValue(forKey: "ocrLanguages")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(decoded.captureDelaySeconds == AppSettings.default.captureDelaySeconds)
        #expect(decoded.ocrLanguages == AppSettings.default.ocrLanguages)
        #expect(decoded.hotkey == AppSettings.default.hotkey)
        #expect(decoded.historyMaxItems == AppSettings.default.historyMaxItems)
    }

    @Test func testNormalizationClampsValues() {
        var settings = AppSettings.default
        settings.jpegQuality = 3
        settings.historyMaxItems = 0
        settings.historyMaxBytes = 1
        settings.saveDirectory = ""
        settings.captureDelaySeconds = 99

        let normalized = settings.normalized()
        #expect(normalized.jpegQuality == 1)
        #expect(normalized.historyMaxItems == 1)
        #expect(normalized.historyMaxBytes == 10 * 1024 * 1024)
        #expect(normalized.saveDirectory.hasSuffix("Pictures/Snipbo"))
        #expect(normalized.captureDelaySeconds == 30)
    }

    @Test func testOCRLanguageNormalizationFiltersDeduplicatesAndFallsBack() {
        var settings = AppSettings.default
        settings.ocrLanguages = ["fr-FR", "zh-Hans", "zh-Hans"]
        #expect(settings.normalized().ocrLanguages == ["zh-Hans"])

        settings.ocrLanguages = []
        #expect(settings.normalized().ocrLanguages == AppSettings.defaultOCRLanguages)
    }

    @Test func testScrollMaxHeightDefaultAndRoundTrip() throws {
        #expect(AppSettings.default.scrollMaxHeight == 20_000)
        var settings = AppSettings.default
        settings.scrollMaxHeight = 42_000
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.scrollMaxHeight == 42_000)
    }

    @Test func testLegacyPayloadWithoutScrollMaxHeightUsesDefault() throws {
        let current = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(
            JSONSerialization.jsonObject(with: current) as? [String: Any]
        )
        object.removeValue(forKey: "scrollMaxHeight")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(decoded.scrollMaxHeight == 20_000)
    }

    @Test func testScrollMaxHeightNormalizationClamps() {
        var settings = AppSettings.default
        settings.scrollMaxHeight = 1
        #expect(settings.normalized().scrollMaxHeight == 1_000)
        settings.scrollMaxHeight = 999_999
        #expect(settings.normalized().scrollMaxHeight == 100_000)
    }

    @Test func testAfterCaptureDefaults() {
        let settings = AppSettings.default
        #expect(settings.afterCaptureCopy)
        #expect(!settings.afterCaptureSave)
    }

    @Test func testAfterCaptureRoundTripAndLegacyDecode() throws {
        var settings = AppSettings.default
        settings.afterCaptureCopy = false
        settings.afterCaptureSave = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(!decoded.afterCaptureCopy)
        #expect(decoded.afterCaptureSave)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "afterCaptureCopy")
        object.removeValue(forKey: "afterCaptureSave")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.afterCaptureCopy == AppSettings.default.afterCaptureCopy)
        #expect(legacy.afterCaptureSave == AppSettings.default.afterCaptureSave)
    }

    @Test func testAfterCaptureNormalizationNeverDiscardsDirectCaptures() {
        // With the editor off, a capture must always go somewhere.
        var settings = AppSettings.default
        settings.openEditorAfterCapture = false
        settings.afterCaptureCopy = false
        settings.afterCaptureSave = false
        let normalized = settings.normalized()
        #expect(normalized.afterCaptureCopy)

        // With the editor on the toggles are inert, so both-off is allowed.
        settings.openEditorAfterCapture = true
        let editorOn = settings.normalized()
        #expect(!editorOn.afterCaptureCopy)
        #expect(!editorOn.afterCaptureSave)
    }

    @Test func testClearHistoryOnQuitDefaultsFalseAndRoundTrips() throws {
        #expect(!AppSettings.default.clearHistoryOnQuit)

        var settings = AppSettings.default
        settings.clearHistoryOnQuit = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.clearHistoryOnQuit)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "clearHistoryOnQuit")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!legacy.clearHistoryOnQuit)
    }

    @Test func testLaunchAtLoginRoundTripAndLegacyDecode() throws {
        var settings = AppSettings.default
        #expect(!settings.launchAtLogin)
        settings.launchAtLogin = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.launchAtLogin)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "launchAtLogin")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!legacy.launchAtLogin)
    }

    @Test func testScrollCaptureFPSDefaultsAndClamps() throws {
        #expect(AppSettings.default.scrollCaptureFPS == 10)
        var settings = AppSettings.default
        settings.scrollCaptureFPS = 20
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).scrollCaptureFPS == 20)

        settings.scrollCaptureFPS = 1
        #expect(settings.normalized().scrollCaptureFPS == 5)
        settings.scrollCaptureFPS = 99
        #expect(settings.normalized().scrollCaptureFPS == 30)

        var object = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(AppSettings.default)) as? [String: Any]
        )
        object.removeValue(forKey: "scrollCaptureFPS")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.scrollCaptureFPS == 10)
    }

    @Test func testCopyOnEditorEscapeRoundTripAndLegacyDecode() throws {
        #expect(!AppSettings.default.copyOnEditorEscape)
        var settings = AppSettings.default
        settings.copyOnEditorEscape = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).copyOnEditorEscape)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "copyOnEditorEscape")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!legacy.copyOnEditorEscape)
    }

    @Test func testHideMenuBarIconDefaultsRoundTripAndLegacyDecode() throws {
        #expect(!AppSettings.default.hideMenuBarIcon)
        var settings = AppSettings.default
        settings.hideMenuBarIcon = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).hideMenuBarIcon)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "hideMenuBarIcon")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!legacy.hideMenuBarIcon)
    }

    @Test func testUILanguageDefaultsAndRoundTrip() throws {
        #expect(AppSettings.default.uiLanguage == .system)
        var settings = AppSettings.default
        settings.uiLanguage = .chinese
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).uiLanguage == .chinese)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "uiLanguage")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.uiLanguage == .system)
    }

    @Test func testModeActionsOverrideAndFallback() {
        var settings = AppSettings.default
        settings.openEditorAfterCapture = false
        settings.afterCaptureCopy = true
        settings.afterCaptureSave = false

        // No override uses the legacy profile.
        #expect(settings.actions(for: "region").copy)
        #expect(!settings.actions(for: "region").openEditor)

        settings.modeActions["window"] = CaptureActions(pin: true)
        let window = settings.actions(for: "window")
        #expect(window.pin)
        #expect(!window.copy)
        #expect(!window.openEditor)

        // An all-off override still leaves the capture a destination.
        settings.modeActions["scrolling"] = CaptureActions()
        #expect(settings.actions(for: "scrolling").copy)
    }

    @Test func testModeActionsNormalizationDropsUnknownModes() {
        var settings = AppSettings.default
        settings.modeActions = [
            "region": CaptureActions(save: true),
            "unknown": CaptureActions(pin: true),
            "window": CaptureActions(),
        ]
        let normalized = settings.normalized()
        #expect(normalized.modeActions["region"]?.save == true)
        #expect(normalized.modeActions["unknown"] == nil)
        #expect(normalized.modeActions["window"]?.copy == true)
    }

    @Test func testModeActionsRoundTripAndLegacyDecode() throws {
        var settings = AppSettings.default
        settings.modeActions["window"] = CaptureActions(openEditor: true, pin: true)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.modeActions["window"] == CaptureActions(openEditor: true, pin: true))

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "modeActions")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.modeActions.isEmpty)
    }

    @Test func testExportDefaultsAndNormalization() {
        let defaults = AppSettings.default
        #expect(defaults.targetFileSizeKB == 0)
        #expect(defaults.fileNameTemplate == "Snipbo-{datetime}")
        #expect(!defaults.watermarkEnabled)
        #expect(!defaults.beautifyEnabled)

        var settings = defaults
        settings.targetFileSizeKB = -10
        settings.fileNameTemplate = "   "
        settings.watermarkOpacity = 5
        settings.beautifyPadding = -1
        settings.beautifyCornerRadius = 999
        let normalized = settings.normalized()
        #expect(normalized.targetFileSizeKB == 0)
        #expect(normalized.fileNameTemplate == "Snipbo-{datetime}")
        #expect(normalized.watermarkOpacity == 1)
        #expect(normalized.beautifyPadding == 0)
        #expect(normalized.beautifyCornerRadius == 80)
    }

    @Test func testExportAppearanceReflectsSettings() {
        var settings = AppSettings.default
        #expect(!settings.exportAppearance.hasWork)

        settings.watermarkEnabled = true
        settings.watermarkText = "Snipbo"
        #expect(settings.exportAppearance.watermark != nil)
        #expect(settings.exportAppearance.beautify == nil)

        settings.beautifyEnabled = true
        #expect(settings.exportAppearance.beautify != nil)

        settings.watermarkText = "   "
        #expect(settings.exportAppearance.watermark == nil)
    }

    @Test func testExportFieldsRoundTripAndLegacyDecode() throws {
        var settings = AppSettings.default
        settings.targetFileSizeKB = 2_048
        settings.fileNameTemplate = "{date}-{app}-{n}"
        settings.watermarkEnabled = true
        settings.watermarkText = "Acme"
        settings.watermarkPosition = .topLeft
        settings.watermarkOpacity = 0.5
        settings.beautifyEnabled = true
        settings.beautifyPadding = 40
        settings.beautifyCornerRadius = 20
        settings.beautifyBackground = .dark
        settings.beautifyShadow = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.targetFileSizeKB == 2_048)
        #expect(decoded.fileNameTemplate == "{date}-{app}-{n}")
        #expect(decoded.watermarkPosition == .topLeft)
        #expect(decoded.beautifyBackground == .dark)
        #expect(!decoded.beautifyShadow)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in [
            "targetFileSizeKB", "fileNameTemplate", "watermarkEnabled",
            "watermarkText", "watermarkPosition", "watermarkOpacity",
            "beautifyEnabled", "beautifyPadding", "beautifyCornerRadius",
            "beautifyBackground", "beautifyShadow",
        ] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.targetFileSizeKB == 0)
        #expect(legacy.fileNameTemplate == "Snipbo-{datetime}")
        #expect(!legacy.watermarkEnabled)
        #expect(!legacy.beautifyEnabled)
    }

    @Test func testSelectionConstraintsDefaultsAndNormalization() {
        #expect(SelectionAspectRatio.square.ratio == 1)
        #expect(abs((SelectionAspectRatio.fourThree.ratio ?? 0) - 4.0 / 3.0) < 0.0001)
        #expect(SelectionAspectRatio.free.ratio == nil)
        #expect(AppSettings.default.selectionSnapToWindows)
        #expect(AppSettings.default.selectionAspectRatio == .free)
        #expect(AppSettings.default.selectionFixedWidth == 0)

        var settings = AppSettings.default
        settings.selectionFixedWidth = 400
        settings.selectionFixedHeight = 0
        let normalized = settings.normalized()
        // A fixed size needs both dimensions; half a lock would be confusing.
        #expect(normalized.selectionFixedWidth == 0)
        #expect(normalized.selectionFixedHeight == 0)

        settings.selectionFixedWidth = 20_000
        settings.selectionFixedHeight = 10_000
        #expect(settings.normalized().selectionFixedWidth == 20_000)
    }

    @Test func testSelectionFieldsRoundTripAndLegacyDecode() throws {
        var settings = AppSettings.default
        settings.selectionSnapToWindows = false
        settings.selectionAspectRatio = .sixteenNine
        settings.selectionFixedWidth = 800
        settings.selectionFixedHeight = 450
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(!decoded.selectionSnapToWindows)
        #expect(decoded.selectionAspectRatio == .sixteenNine)
        #expect(decoded.selectionFixedWidth == 800)
        #expect(decoded.selectionFixedHeight == 450)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in [
            "selectionSnapToWindows", "selectionAspectRatio",
            "selectionFixedWidth", "selectionFixedHeight",
        ] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.selectionSnapToWindows)
        #expect(legacy.selectionAspectRatio == .free)
        #expect(legacy.selectionFixedWidth == 0)
    }

    @Test func testAppearanceDefaultsAndRoundTrip() throws {
        #expect(AppSettings.default.appearance == .system)
        var settings = AppSettings.default
        settings.appearance = .dark
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).appearance == .dark)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "appearance")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.appearance == .system)
    }

    @Test func testRecordingDefaultsAndNormalization() {
        let defaults = AppSettings.default
        #expect(defaults.recordingFormat == .mp4)
        #expect(defaults.recordingFPS == 30)
        #expect(defaults.recordingMaxSeconds == 120)
        #expect(defaults.recordingGIFMaxWidth == 800)

        var settings = defaults
        settings.recordingFPS = 1
        settings.recordingMaxSeconds = 999
        settings.recordingGIFMaxWidth = 100
        let low = settings.normalized()
        #expect(low.recordingFPS == 5)
        #expect(low.recordingMaxSeconds == 600)
        #expect(low.recordingGIFMaxWidth == 240)

        settings.recordingFPS = 99
        settings.recordingMaxSeconds = 1
        settings.recordingGIFMaxWidth = 9_999
        let high = settings.normalized()
        #expect(high.recordingFPS == 30)
        #expect(high.recordingMaxSeconds == 5)
        #expect(high.recordingGIFMaxWidth == 1_920)
    }

    @Test func testRecordingFieldsRoundTripAndLegacyDecode() throws {
        var settings = AppSettings.default
        settings.recordingFormat = .gif
        settings.recordingFPS = 15
        settings.recordingMaxSeconds = 30
        settings.recordingGIFMaxWidth = 1_200
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.recordingFormat == .gif)
        #expect(decoded.recordingFPS == 15)
        #expect(decoded.recordingMaxSeconds == 30)
        #expect(decoded.recordingGIFMaxWidth == 1_200)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in [
            "recordingFormat", "recordingFPS",
            "recordingMaxSeconds", "recordingGIFMaxWidth",
        ] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.recordingFormat == .mp4)
        #expect(legacy.recordingFPS == 30)
        #expect(legacy.recordingMaxSeconds == 120)
        #expect(legacy.recordingGIFMaxWidth == 800)
    }

    @Test func testAppLanguageResolution() {
        // Explicit choices resolve to themselves.
        #expect(AppLanguage.english.resolved == "en")
        #expect(AppLanguage.chinese.resolved == "zh-Hans")
        // System resolution maps zh* to zh-Hans, en* to en, and falls back to en.
        #expect(AppLanguage.system.resolve(["zh-CN", "en"]) == "zh-Hans")
        #expect(AppLanguage.system.resolve(["en-US", "zh-Hans"]) == "en")
        #expect(AppLanguage.system.resolve(["fr-FR"]) == "en")
        // An unsupported first preference falls through to the next supported one.
        #expect(AppLanguage.system.resolve(["ja", "zh-TW"]) == "zh-Hans")
    }

    @Test func autoCheckUpdatesDefaultsTrueAndDecodesFromLegacy() throws {
        // 缺键的旧档解码后为 true(默认开)。
        let legacy = #"{"saveDirectory":"/tmp","format":"png"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(decoded.autoCheckUpdates == true)
        var settings = AppSettings.default
        #expect(settings.autoCheckUpdates == true)
        settings.autoCheckUpdates = false
        let roundtrip = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(roundtrip.autoCheckUpdates == false)
    }
}
