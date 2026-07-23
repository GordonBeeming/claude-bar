import Testing
@testable import ClaudeBarCore

struct UsageDisplayModeTests {
    @Test func usedPassesPercentThrough() {
        #expect(UsageDisplayMode.used.displayPercent(usedPercent: 42) == 42)
    }

    @Test func fuelTankShowsRemaining() {
        #expect(UsageDisplayMode.fuelTank.displayPercent(usedPercent: 42) == 58)
    }

    @Test func fuelTankIsFullAtZeroUsage() {
        #expect(UsageDisplayMode.fuelTank.displayPercent(usedPercent: 0) == 100)
    }

    @Test func fuelTankIsEmptyAtFullUsage() {
        #expect(UsageDisplayMode.fuelTank.displayPercent(usedPercent: 100) == 0)
    }

    @Test func fuelTankClampsPercentOverOneHundred() {
        // A limit reported slightly over 100% must read as an empty tank, not a negative one.
        #expect(UsageDisplayMode.fuelTank.displayPercent(usedPercent: 103) == 0)
    }

    @Test func fillFractionMatchesDisplayedPercent() {
        #expect(UsageDisplayMode.used.fillFraction(usedPercent: 25) == 0.25)
        #expect(UsageDisplayMode.fuelTank.fillFraction(usedPercent: 25) == 0.75)
    }

    @Test func fillFractionClampsOutOfRangeUsage() {
        #expect(UsageDisplayMode.used.fillFraction(usedPercent: 150) == 1)
        #expect(UsageDisplayMode.fuelTank.fillFraction(usedPercent: 150) == 0)
    }

    @Test func markerStaysAtPaceWhenCountingUp() {
        #expect(UsageDisplayMode.used.markerFraction(paceFraction: 0.3) == 0.3)
    }

    @Test func markerMirrorsWhenDraining() {
        #expect(UsageDisplayMode.fuelTank.markerFraction(paceFraction: 0.3) == 0.7)
    }

    @Test func overPaceLeavesTankBelowTheMarker() {
        // Usage 60% with 40% of the window elapsed = over pace. In fuel-tank terms the
        // fill (40% left) must land short of the mirrored marker (60% of the window remains).
        let mode = UsageDisplayMode.fuelTank
        let fill = mode.fillFraction(usedPercent: 60)
        let marker = mode.markerFraction(paceFraction: 0.4)
        #expect(fill < marker)
    }
}
