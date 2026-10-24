import Testing
@testable import SnipboCore

@Suite("CountdownTests")
struct CountdownTests {
    @Test func testCountsDownAndFinishesAtZero() {
        var countdown = Countdown(seconds: 3)
        #expect(countdown.label == "3")

        let firstTick = countdown.tick()
        #expect(!firstTick)
        #expect(countdown.label == "2")

        let secondTick = countdown.tick()
        #expect(!secondTick)
        #expect(countdown.label == "1")

        let thirdTick = countdown.tick()
        #expect(thirdTick)
        #expect(countdown.isFinished)
        #expect(countdown.label == "0")
    }

    @Test func testZeroAndNegativeSecondsAreImmediatelyFinished() {
        var zero = Countdown(seconds: 0)
        #expect(zero.isFinished)
        let zeroTick = zero.tick()
        #expect(zeroTick)

        let negative = Countdown(seconds: -5)
        #expect(negative.isFinished)
        #expect(negative.label == "0")
    }
}
