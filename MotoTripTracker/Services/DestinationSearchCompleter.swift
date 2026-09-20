import Foundation
import MapKit
import os

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
        MKLocalSearch(request: request).start { response, error in
            if let error {
                AppLogger.navigation.error("Local search failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let item = response?.mapItems.first else { return }
            let coordinate = MapKitPlace.coordinate(of: item)
            let name = item.name ?? fallbackName
            Task { @MainActor in
                onResolved(coordinate, name, subtitle)
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            self.searchResults = completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        AppLogger.navigation.error("Search completer failed: \(error.localizedDescription, privacy: .public)")
    }
}
