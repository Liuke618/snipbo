import Testing
@testable import SnipboCore

@Suite("VersionTests")
struct VersionTests {
    @Test func testVersionIsPhaseThree() {
        #expect(snipboVersion == "0.4.0")
    }
}
