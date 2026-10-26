import MapKit
import Observation

/// Stedssøk mens du skriver (Apples søk, som i Kart). Bare teksten sendes, ikke bilder.
/// USA prioriteres. Treffene vises under stedene du allerede har brukt og stedene på turen.
@MainActor @Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    /// Treff for det du har skrevet: tittel («Dupuyer») og undertittel («MT, USA»).
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    /// Bare for områder: nasjonalparker, parker og strender (ikke butikker, gater og byer).
    private let areasOnly: Bool

    init(areasOnly: Bool = false) {
        self.areasOnly = areasOnly
        super.init()
        completer.delegate = self
        if areasOnly {
            completer.resultTypes = [.pointOfInterest]
            completer.pointOfInterestFilter = MKPointOfInterestFilter(including: [.nationalPark, .park, .beach])
        } else {
            completer.resultTypes = [.address, .pointOfInterest]
        }
        completer.region = MKCoordinateRegion(center: .init(latitude: 39, longitude: -98),
                                              span: .init(latitudeDelta: 30, longitudeDelta: 60))
    }

    /// Hvor søket skal prioritere treff (standard: hele USA).
    func prefer(_ region: MKCoordinateRegion?) {
        completer.region = region ?? MKCoordinateRegion(center: .init(latitude: 39, longitude: -98),
                                                        span: .init(latitudeDelta: 30, longitudeDelta: 60))
    }

    var query: String {
        get { completer.queryFragment }
        set {
            let text = newValue.trimmingCharacters(in: .whitespaces)
            if text.count < 2 { results = []; completer.cancel(); return }
            if completer.queryFragment != text {
                results = []  // gamle treff hører til forrige tekst
                completer.queryFragment = text
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = completer.results
        Task { @MainActor in
            // Områder: bare treff i USA (undertittelen har en delstat eller landet).
            let usa = ["USA", "United States", "De Forente Stater"]
            let list = self.areasOnly
                ? found.filter { r in usa.contains { r.subtitle.contains($0) } || r.subtitle.range(of: #", [A-Z]{2}\b"#, options: .regularExpression) != nil }
                : found
            self.results = Array(list.prefix(8))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }

    /// Kartpunkt og navn for et treff. Navnet er tittelen («Dupuyer», «Glacier National Park»).
    func resolve(title: String, subtitle: String) async -> Place? {
        let request: MKLocalSearch.Request
        if let completion = results.first(where: { $0.title == title && $0.subtitle == subtitle }) {
            request = MKLocalSearch.Request(completion: completion)
        } else {
            request = MKLocalSearch.Request()
            request.naturalLanguageQuery = subtitle.isEmpty ? title : "\(title), \(subtitle)"
        }
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let c = item.placemark.coordinate
        return Place(name: title, latitude: c.latitude, longitude: c.longitude)
    }
}
