import CoreLocation
import Foundation

/// Where the rider is searching from — drives adaptive radius and highway bias.
enum PetrolSearchContext: String, Sendable {
    case urban
    case town
    case rural
    case highway

    var displayLabel: String {
        switch self {
        case .urban: "City"
        case .town: "Town"
        case .rural: "Rural"
        case .highway: "Highway"
        }
    }
}

/// Result of adaptive petrol search planning.
struct PetrolSearchPlan: Sendable {
    let context: PetrolSearchContext
    /// Maximum fetch radius (single Overpass query).
    let fetchRadiusMeters: Int
    /// Display/filter radius actually used after expanding tiers.
    let activeRadiusMeters: Int
    /// Whether to boost stations on/near motorways.
    let prioritizeHighway: Bool

    var summary: String {
        let km = Double(activeRadiusMeters) / 1000
        let radiusText = km >= 10 ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
        return "\(context.displayLabel) · within \(radiusText)"
    }
}

/// Chooses search radius and highway bias from local station density and ride speed.
enum PetrolSearchStrategy {
    /// Minimum open-ish stations before we stop expanding radius in dense areas.
    private static let urbanTargetCount = 3
    private static let townTargetCount = 2
    private static let ruralTargetCount = 1

    /// Speed above which we consider highway riding (km/h).
    private static let highwaySpeedKmh = 75.0

    static func plan(
        origin: CLLocationCoordinate2D,
        speedKmh: Double,
        isNearMotorway: Bool,
        stationCountsByRadius: [Int: Int]
    ) -> PetrolSearchPlan {
        let count2km = stationCountsByRadius[2_000] ?? 0
        let count10km = stationCountsByRadius[10_000] ?? 0

        let onHighway = speedKmh >= highwaySpeedKmh && isNearMotorway

        let context: PetrolSearchContext
        if onHighway {
            context = .highway
        } else if count2km >= 4 {
            context = .urban
        } else if count10km >= 2 {
            context = .town
        } else {
            context = .rural
        }

        let tiers: [Int]
        switch context {
        case .urban: tiers = [2_000, 5_000, 10_000]
        case .town: tiers = [5_000, 10_000, 20_000]
        case .rural: tiers = [20_000, 50_000]
        case .highway: tiers = [10_000, 20_000, 50_000]
        }

        let target: Int = switch context {
        case .urban: urbanTargetCount
        case .town: townTargetCount
        case .rural, .highway: ruralTargetCount
        }

        let active = pickActiveRadius(tiers: tiers, counts: stationCountsByRadius, target: target)
        let fetch = tiers.last ?? 50_000

        return PetrolSearchPlan(
            context: context,
            fetchRadiusMeters: fetch,
            activeRadiusMeters: active,
            prioritizeHighway: context == .highway || (onHighway && speedKmh >= 60)
        )
    }

    /// Expand through tiers until we have enough stations or hit the largest tier.
    private static func pickActiveRadius(tiers: [Int], counts: [Int: Int], target: Int) -> Int {
        for radius in tiers {
            if (counts[radius] ?? 0) >= target {
                return radius
            }
        }
        return tiers.last ?? 50_000
    }

    /// Count stations within each tier using pre-fetched distances.
    static func countStations(within radii: [Int], distances: [CLLocationDistance]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for radius in radii.sorted() {
            result[radius] = distances.filter { $0 <= Double(radius) }.count
        }
        return result
    }
}
