import Foundation

/// Which direction a usage figure reads. `.used` (default) counts *up* as a limit is
/// consumed — the number and bar grow toward 100%. `.fuelTank` reverses it into "fuel
/// remaining": the same limit reads as how much is left and drains from full toward empty.
///
/// This is a pure display transform. Severity, over-pace detection, and the underlying
/// API percent are all still keyed to usage — a nearly-empty tank is a nearly-full limit,
/// so it still turns red. Only what the user sees is flipped.
public enum UsageDisplayMode: String, CaseIterable, Sendable {
    /// Percentage consumed. The bar fills up as usage climbs. This is the historical behaviour.
    case used
    /// Percentage remaining. The bar drains down as usage climbs — a fuel gauge.
    case fuelTank

    /// The number to show for a limit whose API-reported *used* percent is `usedPercent`.
    /// `.used` passes it through unchanged; `.fuelTank` shows the remaining fuel, clamped to 0…100
    /// so a limit reported slightly over 100% can't render as a negative tank.
    public func displayPercent(usedPercent: Double) -> Double {
        switch self {
        case .used:
            return usedPercent
        case .fuelTank:
            return min(max(100 - usedPercent, 0), 100)
        }
    }

    /// The fraction (0…1) of a row bar's track to fill. `.used` fills with the used
    /// fraction; `.fuelTank` fills with the remaining fraction, so the bar shrinks as usage
    /// climbs. Clamped so a stray out-of-range percent never overflows or inverts the track.
    public func fillFraction(usedPercent: Double) -> Double {
        min(max(displayPercent(usedPercent: usedPercent), 0), 100) / 100
    }

    /// Where the steady-pace marker sits along the track, given the elapsed-time
    /// `paceFraction` (0…1). `.used` keeps it at elapsed. `.fuelTank` mirrors it to
    /// `1 - paceFraction` so the "over pace = fill falls short of the marker" reading is
    /// preserved once the bar is flipped: burning too fast leaves the tank below the line.
    public func markerFraction(paceFraction: Double) -> Double {
        switch self {
        case .used:
            return paceFraction
        case .fuelTank:
            return 1 - paceFraction
        }
    }
}
