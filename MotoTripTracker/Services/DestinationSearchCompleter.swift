import Foundation
import MapKit
import os

/// MapKit completions are immutable values but not marked Sendable.
extension MKLocalSearchCompletion: @unchecked @retroactive Sendable {}

/// Autocomplete for destination search. Resolving a completion still goes through
/// `NavigationService.beginPreview` so routing stays in one place.
@Observable
@MainActor
final class DestinationSearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            if searchQuery.isEmpty {
                searchResults = []
            } else {
                completer.queryFragment = searchQuery
            }
        }
    }

    private(set) var searchResults: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Starts MapKit's local-search daemon so the first destination sheet isn't cold.
    func warmUp() {
        guard searchQuery.isEmpty else { return }
        completer.queryFragment = " "
        completer.queryFragment = ""
        searchResults = []
    }

    func updateRegion(center: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 60_000,
            longitudinalMeters: 60_000
        )
    }

    func reset() {
        searchQuery = ""
        searchResults = []
    }

    func resolveCompletion(
        _ completion: MKLocalSearchCompletion,
        onResolved: @escaping @MainActor (CLLocationCoordinate2D, String, String) -> Void
    ) {
        let request = MKLocalSearch.Request(completion: completion)
        let fallbackName = completion.title
        let subtitle = completion.subtitle
        Task {
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard let item = response.mapItems.first else { return }
                let coordinate = MapKitPlace.coordinate(of: item)
                let name = item.name ?? fallbackName
                onResolved(coordinate, name, subtitle)
            } catch {
                AppLogger.navigation.error("Local search failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.searchResults = results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        AppLogger.navigation.error("Search completer failed: \(error.localizedDescription, privacy: .public)")
    }
}
