import Foundation
import Testing
@testable import LightShotCore

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
        #expect(settings.saveDirectory.hasSuffix("Pictures/LightShot"))
        #expect(settings.captureDelaySeconds == 3)
        #expect(settings.ocrLanguages == ["zh-Hans", "en-US"])
    }

    @Test func testCodableRoundTrip() throws {
        let settings = AppSettings.default
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
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
        #expect(normalized.saveDirectory.hasSuffix("Pictures/LightShot"))
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

    @Test func testWindowShadowTrimRoundTripAndLegacyDecode() throws {
        #expect(!AppSettings.default.windowShadowTrim)
        var settings = AppSettings.default
        settings.windowShadowTrim = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).windowShadowTrim)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "windowShadowTrim")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!legacy.windowShadowTrim)
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
}
