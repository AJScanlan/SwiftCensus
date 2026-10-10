import Testing

@testable import CensusRunner

@Suite struct ElapsedTests {
    @Test func roundsToATenthOfASecond() {
        #expect(Elapsed.seconds(.milliseconds(1234)) == 1.2)
        #expect(Elapsed.seconds(.milliseconds(1250)) == 1.3)
        #expect(Elapsed.seconds(.seconds(90)) == 90)
        #expect(Elapsed.seconds(.zero) == 0)
    }
}
