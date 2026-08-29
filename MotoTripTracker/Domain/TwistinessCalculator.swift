import Foundation

/// Composite twistiness score (0–100) from corner density and lateral G.
enum TwistinessCalculator {
    enum Rating: String, Sendable {
        case straight = "Straight"
        case flowing = "Flowing"
        case twisty = "Twisty"
        case epic = "Epic twisties"

        var systemImage: String {
            switch self {
            case .straight: "arrow.forward"
            case .flowing: "arrow.triangle.turn.up.right.diamond"
            case .twisty: "point.topleft.down.to.point.bottomright.curvepath"
            case .epic: "flame.fill"
            }
        }
    }

    /// Score from persisted trip aggregates.
    static func score(
        cornerCount: Int,
        distanceKm: Double,
        maxLateralGForce: Double
    ) -> Double {
        guard distanceKm >= 0.5, cornerCount > 0 else { return 0 }

        let cornersPer10Km = Double(cornerCount) / distanceKm * 10
        // ~15 corners / 10 km ≈ very twisty road.
        let densityScore = min(100, cornersPer10Km / 15 * 100)

        // ~0.8 G lateral peak ≈ spirited cornering on a bike.
        let lateralScore = min(100, max(maxLateralGForce, 0) / 0.8 * 100)

        return min(100, densityScore * 0.72 + lateralScore * 0.28)
    }

    static func score(for trip: Trip) -> Double {
        if trip.twistinessScore > 0 {
            return trip.twistinessScore
        }
        return score(
            cornerCount: trip.cornerCount,
            distanceKm: trip.distanceKm,
            maxLateralGForce: trip.maxLateralGForce
        )
    }

    static func rating(for score: Double) -> Rating {
        switch score {
        case ..<25: .straight
        case ..<50: .flowing
        case ..<75: .twisty
        default: .epic
        }
    }

    static func formattedScore(_ score: Double) -> String {
        String(format: "%.0f", score.rounded())
    }

    static func cornersPer10Km(cornerCount: Int, distanceKm: Double) -> Double {
        guard distanceKm >= 0.5 else { return 0 }
        return Double(cornerCount) / distanceKm * 10
    }
}
