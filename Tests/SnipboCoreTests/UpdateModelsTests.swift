import Testing
@testable import SnipboCore

@Suite("UpdateModelsTests")
struct UpdateModelsTests {
    @Test func parsesLeadingV() {
        #expect(SemVer.parse("v0.5.0") == SemVer(major: 0, minor: 5, patch: 0))
        #expect(SemVer.parse("0.5.0")?.description == "0.5.0")
    }

    @Test func padsMissingSegments() {
        // 1.0 == 1.0.0,右侧补零后相等。
        #expect(SemVer.compare("v1.0", "1.0.0") == .orderedSame)
    }

    @Test func ordersBySegment() {
        #expect(SemVer.compare("v0.4.0", "v0.5.0") == .orderedAscending)
        #expect(SemVer.compare("0.10.0", "0.9.0") == .orderedDescending)
    }

    @Test func prereleaseIsIncomparable() {
        // -beta 等非数字段无法判断,不提示更新。
        #expect(SemVer.compare("v1.0.0-rc1", "v1.0.0") == nil)
        #expect(SemVer.compare("not-a-version", "v1.0.0") == nil)
    }

    @Test func errorMessagesAreLocalized() {
        #expect(!UpdateError.channelUnavailable.localizedDescription.isEmpty)
        #expect(!UpdateError.rateLimited.localizedDescription.isEmpty)
    }
}
