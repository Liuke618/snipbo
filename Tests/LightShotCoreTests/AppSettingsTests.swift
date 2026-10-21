import Foundation
import Testing
@testable import LightShotCore

@Suite("AppSettingsTests")
struct AppSettingsTests {
    @Test func testDefaults() {
        let settings = AppSettings.default
        #expect(settings.hotkey == Hotkey(keyCode: 26, modifiers: [.command, .shift]))
        #expect(settings.format == .png)
        #expect(settings.openEditorAfterCapture)
        #expect(settings.historyEnabled)
        #expect(settings.historyMaxItems == 200)
        #expect(settings.historyMaxBytes == 500 * 1024 * 1024)
        #expect(!settings.captureCursor)
        #expect(settings.saveDirectory.hasSuffix("Pictures/LightShot"))
    }

    @Test func testCodableRoundTrip() throws {
        let settings = AppSettings.default
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func testNormalizationClampsValues() {
        var settings = AppSettings.default
        settings.jpegQuality = 3
        settings.historyMaxItems = 0
        settings.historyMaxBytes = 1
        settings.saveDirectory = ""

        let normalized = settings.normalized()
        #expect(normalized.jpegQuality == 1)
        #expect(normalized.historyMaxItems == 1)
        #expect(normalized.historyMaxBytes == 10 * 1024 * 1024)
        #expect(normalized.saveDirectory.hasSuffix("Pictures/LightShot"))
    }
}
