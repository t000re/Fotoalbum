import CoreLocation
import MapKit

/// Steder i nærheten av bildets kartpunkt (nasjonalparker, monumenter, verneområder, utsiktspunkter …),
/// som alternative navn på stedet. Apples stedssøk (bare kartpunktet og søkeordene sendes).
extension AppModel {
    /// Søkeord som gir naturlige steder (rene «steder i nærheten»-oppslag gir for lite utenfor byer),
    /// med nivå (lavere = viktigere) og ord navnet må inneholde for å telle.
    private static let nearbyQueries: [(query: String, tier: Int, mustContain: [String])] = [
        ("national park", 0, ["national park", "nasjonalpark"]),
        ("national monument", 0, ["national monument"]),
        ("conservation area", 0, ["conservation area", "national recreation area"]),
        ("state park", 0, ["state park"]),
        ("wilderness", 1, ["wilderness", "preserve", "reserve"]),
        ("overlook", 1, ["overlook", "viewpoint", "vista", "point", "bluffs"]),
    ]
    /// Treff med disse ordene er ikke steder man tar bilder «på».
    private static let nearbyNoise = ["visitor center", "information center", "road", " lane", "golf", "rental", "society", "marker", "hotel", "inn", "motel", "office",
                                      "parking", "store", "shop", "restaurant", "cafe", "realty", "trading",
                                      "rv park", "campground", "school", "church", "alliance", "association",
                                      "foundation", "trailhead"]

    /// Bilder innen ca. 10 km deler forslag (færre oppslag; Apple begrenser antall søk per minutt).
    private func nearbyKey(_ p: GeoPoint) -> String { String(format: "%.1f,%.1f", p.lat, p.lon) }

    /// Forslagene for et kartpunkt (tom liste til de er hentet).
    func nearbyPlaces(_ p: GeoPoint) -> [FocusSession.Option] { nearbyPOIs[nearbyKey(p)] ?? [] }

    /// Henter steder innen ca. 40 km, nærmeste først, høyst 8. Hvert punkt slås opp én gang.
    func loadNearbyPlaces(_ p: GeoPoint) async {
        let key = nearbyKey(p)
        guard nearbyPOIs[key] == nil else { return }
        nearbyPOIs[key] = []
        let here = CLLocation(latitude: p.lat, longitude: p.lon)
        var found: [(name: String, km: Double, tier: Int)] = []
        func add(_ name: String?, _ km: Double, _ tier: Int) {
            guard let name, !name.isEmpty else { return }
            let lower = " " + name.lowercased()
            // Gateforkortelser sjekkes som hele ord («St» er gate, «State Park» er ikke det).
            let words = Set(name.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "." }).map(String.init))
            guard !Self.nearbyNoise.contains(where: { lower.contains($0) }),
                  words.isDisjoint(with: ["rd", "rd.", "st", "st.", "ln", "ln.", "ave", "ave.", "co", "co.", "blvd", "hwy"])
            else { return }
            if let i = found.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                found[i].tier = min(found[i].tier, tier)
            } else {
                found.append((name, km, tier))
            }
        }
        // Severdigheten/parken punktet ligger i, fra stedsoppslaget (øverst).
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(here, preferredLocale: Locale(identifier: "en_US")).first {
            for aoi in placemark.areasOfInterest ?? [] { add(aoi, 0, -1) }
        }
        let region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        await withTaskGroup(of: [(String, Double, Int)].self) { group in
            for (query, tier, mustContain) in Self.nearbyQueries {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = query
                    request.region = region
                    request.resultTypes = .pointOfInterest
                    guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return [] }
                    return items.compactMap { item in
                        let name = item.name ?? ""
                        guard mustContain.contains(where: { name.lowercased().contains($0) }) else { return nil }
                        let c = item.placemark.coordinate
                        let km = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) / 1000
                        return km <= 40 ? (name, km, tier) : nil
                    }
                }
            }
            for await results in group { for (name, km, tier) in results { add(name, km, tier) } }
        }
        // Viktigste type først (nasjonalpark, monument, verneområde …), så nærmeste.
        nearbyPOIs[key] = found.sorted { ($0.tier, $0.km) < ($1.tier, $1.km) }.prefix(8).map { poi in
            .init(title: poi.name, detail: poi.km < 1 ? "her" : "i nærheten · \(Int(poi.km.rounded())) km",
                  place: Place(name: poi.name, latitude: p.lat, longitude: p.lon))
        }
    }
}
