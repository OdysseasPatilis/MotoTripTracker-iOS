import Foundation

/// Motorcycle-aware travel time from MapKit’s car (traffic) ETA.
///
/// Bikes can filter, so car delays are only partly applied. We learn a personal
/// filter benefit from completed navigations (actual duration vs car estimate).
enum MotoTravelEstimator {
    /// Assumed free-flow motorcycle pace for baseline (urban / peri-urban).
    static let freeFlowSpeedMps: Double = 50.0 / 3.6
    static let defaultFilterBenefit: Double = 0.45
    private static let benefitKey = "moto_nav_filter_benefit"

    struct Estimate: Equatable, Sendable {
        let carTravelTime: TimeInterval
        let baselineTravelTime: TimeInterval
        /// Excess of car ETA over free-flow baseline (traffic / lights / congestion).
        let trafficDelay: TimeInterval
        let motoTravelTime: TimeInterval
        let filterBenefit: Double
    }

    static var storedFilterBenefit: Double {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: benefitKey) == nil { return defaultFilterBenefit }
            return defaults.double(forKey: benefitKey)
        }
        set {
            let clamped = min(max(newValue, 0.15), 0.75)
            UserDefaults.standard.set(clamped, forKey: benefitKey)
        }
    }

    static func estimate(
        distanceMeters: Double,
        carTravelTime: TimeInterval,
        filterBenefit: Double = storedFilterBenefit
    ) -> Estimate {
        let baseline = max(distanceMeters / freeFlowSpeedMps, 45)
        let delay = max(0, carTravelTime - baseline)
        let benefit = min(max(filterBenefit, 0.15), 0.75)
        let moto = baseline + delay * (1 - benefit)
        return Estimate(
            carTravelTime: carTravelTime,
            baselineTravelTime: baseline,
            trafficDelay: delay,
            motoTravelTime: max(moto, 30),
            filterBenefit: benefit
        )
    }

    /// Update personal filter factor after a completed navigation.
    static func learn(from result: NavTimingResult) {
        guard result.carEstimate > 60, result.actual > 30 else { return }
        let estimate = Self.estimate(
            distanceMeters: result.distanceMeters,
            carTravelTime: result.carEstimate,
            filterBenefit: storedFilterBenefit
        )
        guard estimate.trafficDelay > 30 else { return }

        // How much of the car delay the rider actually avoided.
        let observedBenefit = 1 - ((result.actual - estimate.baselineTravelTime) / estimate.trafficDelay)
        let clamped = min(max(observedBenefit, 0.15), 0.75)
        storedFilterBenefit = 0.72 * storedFilterBenefit + 0.28 * clamped
    }

    static func formatMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(minutes) min"
    }
}

/// Outcome of one guided navigation leg (Start → clear).
struct NavTimingResult: Equatable, Sendable {
    let distanceMeters: Double
    let carEstimate: TimeInterval
    let motoEstimate: TimeInterval
    let actual: TimeInterval

    /// Positive means finished faster than the car ETA.
    var savedVersusCar: TimeInterval { carEstimate - actual }

    var summaryLine: String {
        let actualMin = MotoTravelEstimator.formatMinutes(actual)
        if savedVersusCar >= 45 {
            let saved = MotoTravelEstimator.formatMinutes(savedVersusCar)
            return "You did it in \(actualMin) — \(saved) faster than car traffic ETA"
        }
        if savedVersusCar <= -45 {
            let slower = MotoTravelEstimator.formatMinutes(-savedVersusCar)
            return "Took \(actualMin) — \(slower) slower than car traffic ETA"
        }
        return "Done in \(actualMin) — close to car traffic ETA"
    }
}
