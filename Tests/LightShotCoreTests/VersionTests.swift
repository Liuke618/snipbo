import Testing
@testable import LightShotCore

@Suite("VersionTests")
struct VersionTests {
    @Test func testVersionIsPhaseOne() {
        #expect(lightShotVersion == "0.1.0")
    }
}
