import CoreLocation
import MapKit

/// Stedslista: stedene på turen fra iPhone-bildenes GPS, med navn fra stedsoppslag.
extension AppModel {
    var tripPlaces: [TripPlace] { project.tripPlaces ?? [] }

    /// Lager lista på nytt fra iPhone-bildene. Navn du har gitt selv, beholdes for steder på samme sted.
    /// Navn slås opp ett om gangen (Apple tillater ikke mange oppslag i sekundet), og like navn slås sammen.
    func buildTripPlaces(from phone: PhoneLibrary) async {
        let clusters = PlaceClustering.clusters(phone.located)
        let old = tripPlaces
        var places: [TripPlace] = clusters.map { c in
            let center = c.center
            let keep = old.first { $0.renamed && distanceKm($0.point, center) < 8 }
            return TripPlace(id: keep?.id ?? UUID(), name: keep?.name ?? "",
                             latitude: center.lat, longitude: center.lon,
                             firstDay: c.firstDay, lastDay: c.lastDay, photoCount: c.count, renamed: keep != nil)
        }
        project.tripPlaces = places
        placesProgress = (0, places.count)
        for i in places.indices where places[i].name.isEmpty {
            // Gjenbruk navn fra forrige gang for samme sted.
            if let same = old.first(where: { !$0.name.isEmpty && distanceKm($0.point, places[i].point) < 3 }) {
                places[i].name = same.name
            } else {
                let location = CLLocation(latitude: places[i].latitude, longitude: places[i].longitude)
                places[i].name = await phone.areaName(for: location) ?? String(format: "%.2f, %.2f", places[i].latitude, places[i].longitude)
                try? await Task.sleep(for: .milliseconds(700))
            }
            placesProgress = (i + 1, places.count)
            project.tripPlaces = Self.mergeSameName(places)
        }
        project.tripPlaces = Self.mergeSameName(places)
        placesProgress = nil
        scheduleSave()
    }

    /// Steder med samme navn (f.eks. flere deler av Yosemite) blir ett.
    static func mergeSameName(_ places: [TripPlace]) -> [TripPlace] {
        var result: [TripPlace] = []
        for p in places {
            if !p.name.isEmpty, let i = result.firstIndex(where: { $0.name == p.name }) {
                let total = Double(result[i].photoCount + p.photoCount)
                result[i].latitude = (result[i].latitude * Double(result[i].photoCount) + p.latitude * Double(p.photoCount)) / total
                result[i].longitude = (result[i].longitude * Double(result[i].photoCount) + p.longitude * Double(p.photoCount)) / total
                result[i].photoCount += p.photoCount
                result[i].firstDay = min(result[i].firstDay, p.firstDay)
                result[i].lastDay = max(result[i].lastDay, p.lastDay)
                result[i].renamed = result[i].renamed || p.renamed
            } else {
                result.append(p)
            }
        }
        return result.sorted { $0.firstDay < $1.firstDay }
    }

    func renameTripPlace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var places = project.tripPlaces, let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].name = trimmed
        places[i].renamed = true
        project.tripPlaces = places
        scheduleSave()
    }

    /// Gir de valgte bildene stedet. Er stedet bare fra én dag, og bildet mangler dato, settes datoen også.
    func applyTripPlace(_ place: TripPlace) {
        for id in selectedIDs where info(id).day == nil && place.firstDay == place.lastDay {
            update(id) { $0.day = place.firstDay }
        }
        apply(day: nil, place: place.place, source: .manual)
    }

    // MARK: Forslag og kartpunkt

    /// Stedsnavn som passer det du skriver: først steder på turen, så navn du har brukt.
    func placeSuggestions(for text: String) -> [Place] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        func matches(_ name: String) -> Bool { name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        var result: [Place] = tripPlaces.filter { matches($0.name) }.map(\.place)
        for (name, ids) in placeNames where matches(name) && !result.contains(where: { $0.name == name }) {
            // Bruk koordinatene fra et bilde som har dem.
            let withCoordinates = ids.compactMap { info($0).place }.first { $0.latitude != nil }
            result.append(withCoordinates ?? Place(name: name))
        }
        // De som begynner med teksten først.
        return Array(result.sorted { a, b in
            let pa = a.name.lowercased().hasPrefix(query.lowercased()), pb = b.name.lowercased().hasPrefix(query.lowercased())
            return pa && !pb
        }.prefix(6))
    }

    /// Finner kartpunkt for et stedsnavn med Apples stedssøk (bare navnet sendes). Foretrekker USA.
    static func lookUpCoordinates(_ name: String) async -> GeoPoint? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(center: .init(latitude: 39, longitude: -98),
                                            span: .init(latitudeDelta: 30, longitudeDelta: 60))
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let c = item.placemark.coordinate
        return GeoPoint(lat: c.latitude, lon: c.longitude)
    }

    /// Søker etter et sted ut fra tekst (f.eks. fra et skilt). Gir navn («Montana», «Grand Canyon
    /// National Park») og kartpunkt, eller nil.
    static func lookUpPlace(_ text: String) async -> Place? {
        // Vanlige skiltord tas bort: «Welcome to Montana» → «Montana».
        var query = text
        for word in ["welcome to", "entering", "leaving", "you are now in", "city limits", "city limit", "the state of", "state line"] {
            query = query.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !query.isEmpty else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(center: .init(latitude: 39, longitude: -98),
                                            span: .init(latitudeDelta: 30, longitudeDelta: 60))
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let c = item.placemark.coordinate
        let name = item.name ?? item.placemark.locality ?? text
        return Place(name: name, latitude: c.latitude, longitude: c.longitude)
    }

    /// Gir alle bilder med stedsnavnet kartpunkt, hvis de mangler det.
    func setCoordinates(_ point: GeoPoint, forPlaceNamed name: String) {
        for (id, info) in project.photos where info.place?.name == name && info.place?.latitude == nil {
            update(id) { $0.place?.latitude = point.lat; $0.place?.longitude = point.lon }
        }
    }

    /// Steder uten kartpunkt (skrevet inn for hånd).
    var placesWithoutCoordinates: [String] {
        placeNames.filter { entry in entry.ids.allSatisfy { info($0).place?.latitude == nil } }.map(\.name)
    }

    /// Slår opp kartpunkt for alle steder som mangler det.
    func findMissingCoordinates() async -> (found: Int, missing: [String]) {
        var found = 0, missing: [String] = []
        for name in placesWithoutCoordinates {
            if let point = await Self.lookUpCoordinates(name) {
                setCoordinates(point, forPlaceNamed: name)
                found += 1
            } else {
                missing.append(name)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return (found, missing)
    }
}
