import Foundation
import os

/// Tracks tank capacity, remaining fuel, and estimated range for the active bike.
/// Persists simple preferences in UserDefaults (no SwiftData migration required).
@Observable
@MainActor
final class FuelService {
    private static let capacityKey = "moto.fuel.tankCapacityLiters"
    private static let remainingKey = "moto.fuel.remainingLiters"
    private static let consumptionKey = "moto.fuel.consumptionLPer100Km"
    private static let lastFillKey = "moto.fuel.lastFillDate"

    private static let defaultCapacity = 16.0
    private static let defaultConsumption = 5.5

    private var _tankCapacityLiters: Double
    private var _fuelRemainingLiters: Double
    private var _consumptionLPer100Km: Double

    var tankCapacityLiters: Double {
        get { _tankCapacityLiters }
        set {
            let clamped = Self.clamp(newValue, min: 5, max: 40)
            _tankCapacityLiters = clamped
            UserDefaults.standard.set(clamped, forKey: Self.capacityKey)
            if _fuelRemainingLiters > clamped {
                fuelRemainingLiters = clamped
            }
        }
    }

    var fuelRemainingLiters: Double {
        get { _fuelRemainingLiters }
        set {
            let clamped = Self.clamp(newValue, min: 0, max: _tankCapacityLiters)
            _fuelRemainingLiters = clamped
            UserDefaults.standard.set(clamped, forKey: Self.remainingKey)
        }
    }

    /// Liters per 100 km.
    var consumptionLPer100Km: Double {
        get { _consumptionLPer100Km }
        set {
            let clamped = Self.clamp(newValue, min: 2.5, max: 12)
            _consumptionLPer100Km = clamped
            UserDefaults.standard.set(clamped, forKey: Self.consumptionKey)
        }
    }

    private(set) var lastFillDate: Date?

    /// Distance already accounted for in the current ride (km).
    private var consumedDistanceKmThisRide: Double = 0

    init() {
        let defaults = UserDefaults.standard
        let capacity = Self.clamp(
            defaults.object(forKey: Self.capacityKey) as? Double ?? Self.defaultCapacity,
            min: 5,
            max: 40
        )
        _tankCapacityLiters = capacity
        _fuelRemainingLiters = Self.clamp(
            defaults.object(forKey: Self.remainingKey) as? Double ?? capacity,
            min: 0,
            max: capacity
        )
        _consumptionLPer100Km = Self.clamp(
            defaults.object(forKey: Self.consumptionKey) as? Double ?? Self.defaultConsumption,
            min: 2.5,
            max: 12
        )
        if let interval = defaults.object(forKey: Self.lastFillKey) as? TimeInterval {
            lastFillDate = Date(timeIntervalSince1970: interval)
        }
    }

    var rangeRemainingKm: Double {
        guard _consumptionLPer100Km > 0 else { return 0 }
        return (_fuelRemainingLiters / _consumptionLPer100Km) * 100
    }

    var fuelFraction: Double {
        guard _tankCapacityLiters > 0 else { return 0 }
        return _fuelRemainingLiters / _tankCapacityLiters
    }

    var isLowFuel: Bool {
        fuelFraction < 0.2 || rangeRemainingKm < 40
    }

    var rangeSummary: String {
        if rangeRemainingKm >= 10 {
            return String(format: "~%.0f km range", rangeRemainingKm)
        }
        return String(format: "~%.0f km left", max(0, rangeRemainingKm))
    }

    func fillUp() {
        fuelRemainingLiters = tankCapacityLiters
        lastFillDate = Date()
        UserDefaults.standard.set(lastFillDate!.timeIntervalSince1970, forKey: Self.lastFillKey)
        AppLogger.app.notice("Fuel filled to \(self.tankCapacityLiters, format: .fixed(precision: 1)) L")
    }

    func addFuel(liters: Double) {
        fuelRemainingLiters = min(tankCapacityLiters, fuelRemainingLiters + max(0, liters))
        lastFillDate = Date()
        UserDefaults.standard.set(lastFillDate!.timeIntervalSince1970, forKey: Self.lastFillKey)
    }

    func resetRideConsumption() {
        consumedDistanceKmThisRide = 0
    }

    /// Burns fuel based on distance ridden this session (called as trip distance grows).
    func updateConsumedDistance(tripDistanceKm: Double) {
        let delta = max(0, tripDistanceKm - consumedDistanceKmThisRide)
        guard delta > 0.01 else { return }
        consumedDistanceKmThisRide = tripDistanceKm
        let litersUsed = delta * consumptionLPer100Km / 100
        fuelRemainingLiters = max(0, fuelRemainingLiters - litersUsed)
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }
}
