import ClaudeBarCore
import MacReactions

/// Plays a reaction over the whole screen. MacReactions owns the transparent
/// click-through overlay windows, lazy setup/teardown, and Reduce Motion (its default
/// `.system` policy follows the accessibility setting), so this is just the map from
/// our `ReactionChoice` onto the library's `Reaction`.
@MainActor
final class CelebrationController {
    func play(_ choice: ReactionChoice) {
        ReactionCenter.shared.play(reaction(for: choice), on: .screen)
    }

    private func reaction(for choice: ReactionChoice) -> Reaction {
        switch choice {
        case .confetti: return .confetti
        case .balloons: return .balloons
        case .fireworks: return .fireworks
        case .rain: return .rain
        case .lasers: return .lasers
        case .hearts: return .hearts
        case .thumbsUp: return .thumbsUp
        case .thumbsDown: return .thumbsDown
        }
    }
}
