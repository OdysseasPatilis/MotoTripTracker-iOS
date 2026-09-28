import CoreLocation
import Foundation
import Testing
@testable import MotoTripTracker

struct NavigationCueFormattingTests {
    @Test func chipUsesDistanceAndStreet() {
        let text = NavigationCueFormatting.chipText(
            distanceMeters: 120,
            instruction: "Turn left onto Ermou"
        )
        #expect(text == "120 m Ermou")
    }

    @Test func compactLabelPrefersTheStreetAfterOntoOrOn() {
        #expect(NavigationCueFormatting.compactLabel(from: "Turn right onto Athinas") == "Athinas")
        #expect(NavigationCueFormatting.compactLabel(from: "Keep left to stay on Panepistimiou") == "Panepistimiou")
        #expect(
            NavigationCueFormatting.compactLabel(from: "Continue on Ermou for 2 kilometers") == "Ermou"
        )
        #expect(
            NavigationCueFormatting.compactLabel(from: "At the roundabout, take the 2nd exit onto Leoforos Athinon")
            == "Leoforos Athinon"
        )
    }

    @Test func compactLabelFallsBackToAShortManeuver() {
        #expect(NavigationCueFormatting.compactLabel(from: "Turn left") == "Left")
        #expect(NavigationCueFormatting.compactLabel(from: "Make a U-turn") == "U-turn")
        #expect(NavigationCueFormatting.compactLabel(from: "Arrive at destination") == "Destination")
        #expect(NavigationCueFormatting.compactLabel(from: "Continue straight") == "Straight")
    }

    @Test func remainingTimeLabel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(NavigationCueFormatting.remainingTimeLabel(until: nil, now: now) == "--")
        #expect(
            NavigationCueFormatting.remainingTimeLabel(until: now.addingTimeInterval(18 * 60), now: now) == "18 min"
        )
        #expect(
            NavigationCueFormatting.remainingTimeLabel(until: now.addingTimeInterval(20), now: now) == "now"
        )
        #expect(
            NavigationCueFormatting.remainingTimeLabel(until: now.addingTimeInterval(90 * 60), now: now) == "1h 30m"
        )
    }
}

struct DestinationAndNavTests {

    @Test func destinationHistoryAddsNewestFirstAndCapsAt20() {
        let suiteName = "test.moto.nav.history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for i in 0..<25 {
            DestinationSearchHistory.add(
                name: "Place \(i)",
                subtitle: "Sub \(i)",
                latitude: 37.9 + Double(i) * 0.001,
                longitude: 23.7,
                defaults: defaults
            )
        }
        let all = DestinationSearchHistory.all(defaults: defaults)
        #expect(all.count == 20)
        #expect(all.first?.name == "Place 24")
        #expect(all.last?.name == "Place 5")
    }

    @Test func destinationHistoryDedupesNearbyCoordinateToTop() {
        let suiteName = "test.moto.nav.history.dedupe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DestinationSearchHistory.add(
            name: "Old",
            subtitle: "A",
            latitude: 37.9800,
            longitude: 23.7200,
            defaults: defaults
        )
        DestinationSearchHistory.add(
            name: "Other",
            subtitle: "B",
            latitude: 38.0,
            longitude: 24.0,
            defaults: defaults
        )
        DestinationSearchHistory.add(
            name: "Updated",
            subtitle: "C",
            latitude: 37.98001,
            longitude: 23.72001,
            defaults: defaults
        )
        let all = DestinationSearchHistory.all(defaults: defaults)
        #expect(all.count == 2)
        #expect(all[0].name == "Updated")
        #expect(all[0].subtitle == "C")
    }

    @Test func destinationHistoryRemoveById() {
        let suiteName = "test.moto.nav.history.remove.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DestinationSearchHistory.add(
            name: "Keep",
            subtitle: "",
            latitude: 1,
            longitude: 2,
            defaults: defaults
        )
        DestinationSearchHistory.add(
            name: "Drop",
            subtitle: "",
            latitude: 3,
            longitude: 4,
            defaults: defaults
        )
        let dropID = DestinationSearchHistory.all(defaults: defaults).first { $0.name == "Drop" }!.id
        DestinationSearchHistory.remove(id: dropID, defaults: defaults)
        let names = DestinationSearchHistory.all(defaults: defaults).map(\.name)
        #expect(names == ["Keep"])
    }

    @Test @MainActor func routePreviewWaitsForGpsThenRetries() {
        let service = NavigationService()
        let destination = CLLocationCoordinate2D(latitude: 37.9838, longitude: 23.7275)

        service.beginPreview(coordinate: destination, name: "Destination")

        #expect(service.isPreviewing)
        #expect(!service.isRouting)
        #expect(service.previewRoutes.isEmpty)
        #expect(service.previewErrorMessage == "Waiting for your location…")

        service.updateOrigin(CLLocationCoordinate2D(latitude: 37.97, longitude: 23.71))

        #expect(service.isRouting)
        #expect(service.previewErrorMessage == nil)
    }

    @Test func motoTravelEstimatorCutsCarTrafficDelay() {
        let distanceMeters = 10_000.0
        let car: TimeInterval = 30 * 60
        let estimate = MotoTravelEstimator.estimate(
            distanceMeters: distanceMeters,
            carTravelTime: car,
            filterBenefit: 0.5
        )
        #expect(estimate.trafficDelay > 0)
        #expect(estimate.motoTravelTime < estimate.carTravelTime)
        #expect(estimate.motoTravelTime > estimate.baselineTravelTime)
    }

    @Test func motoTravelEstimatorLearnsFromBeatingCarETA() {
        let before = MotoTravelEstimator.storedFilterBenefit
        defer { MotoTravelEstimator.storedFilterBenefit = before }

        MotoTravelEstimator.storedFilterBenefit = 0.40
        let result = NavTimingResult(
            distanceMeters: 12_000,
            carEstimate: 40 * 60,
            motoEstimate: 28 * 60,
            actual: 22 * 60
        )
        MotoTravelEstimator.learn(from: result)
        #expect(MotoTravelEstimator.storedFilterBenefit > 0.40)
    }
}
