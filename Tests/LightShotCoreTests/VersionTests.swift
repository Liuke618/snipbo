import Testing
@testable import LightShotCore

@Suite("VersionTests")
struct VersionTests {
    @Test func testVersionIsPhaseTwo() {
        #expect(lightShotVersion == "0.2.0")
    }
}
