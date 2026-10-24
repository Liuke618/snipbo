import Testing
@testable import LightShotCore

@Suite("VersionTests")
struct VersionTests {
    @Test func testVersionIsPhaseThree() {
        #expect(lightShotVersion == "0.3.0")
    }
}
