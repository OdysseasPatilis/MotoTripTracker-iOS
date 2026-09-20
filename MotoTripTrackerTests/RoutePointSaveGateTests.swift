import Foundation
import Testing
@testable import MotoTripTracker

struct RoutePointSaveGateTests {
    private let t0: TimeInterval = 1_000_000

    @Test func holdsUntilFivePointsWhenTicksAreClose() {
        var gate = RoutePointSaveGate()
        let first = gate.recordPoint(at: t0)
        let second = gate.recordPoint(at: t0 + 0.8)
        let third = gate.recordPoint(at: t0 + 1.6)
        let fourth = gate.recordPoint(at: t0 + 2.4)
        let fifth = gate.recordPoint(at: t0 + 3.2)
        #expect(!first)
        #expect(!second)
        #expect(!third)
        #expect(!fourth)
        #expect(fifth)
    }

    @Test func savesWhenFourSecondsElapseEvenWithFewPoints() {
        var gate = RoutePointSaveGate()
        let first = gate.recordPoint(at: t0)
        let later = gate.recordPoint(at: t0 + 4)
        #expect(!first)
        #expect(later)
    }

    @Test func doesNotSaveOnTimeIfIntervalIsJustUnderThreshold() {
        var gate = RoutePointSaveGate()
        let first = gate.recordPoint(at: t0)
        let soon = gate.recordPoint(at: t0 + 3.9)
        #expect(!first)
        #expect(!soon)
    }

    @Test func flushReportsPendingThenClears() {
        var gate = RoutePointSaveGate()
        let emptyFlush = gate.consumeFlush()
        let recorded = gate.recordPoint(at: t0)
        let pendingFlush = gate.consumeFlush()
        let secondFlush = gate.consumeFlush()
        #expect(!emptyFlush)
        #expect(!recorded)
        #expect(pendingFlush)
        #expect(!secondFlush)
    }

    @Test func resetClearsPendingWithoutReportingFlush() {
        var gate = RoutePointSaveGate()
        let recorded = gate.recordPoint(at: t0)
        gate.reset()
        let flushed = gate.consumeFlush()
        let afterReset = gate.recordPoint(at: t0 + 1)
        #expect(!recorded)
        #expect(!flushed)
        #expect(!afterReset)
    }
}
