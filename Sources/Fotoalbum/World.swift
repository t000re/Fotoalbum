import Foundation

/// Et land eller en region (stat, fylke, provins …) med omriss, fra Natural Earth
/// (se tools/make-world.py). Kode: land = ISO 3166-1 («US», «NO»), region = ISO 3166-2 («US-NM», «NO-12»).
struct GeoArea: Hashable {
    let code: String
    let name: String
    /// Type på engelsk fra Natural Earth («State», «County», «Province» …); tom for land.
    let kind: String
    /// Landet regionen ligger i (ISO 3166-1); for land: koden selv.
    let country: String
    let minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    let rings: [[GeoPoint]]

    func contains(_ p: GeoPoint) -> Bool {
        guard p.lat >= minLat, p.lat <= maxLat, p.lon >= minLon, p.lon <= maxLon else { return false }
        return rings.contains { USState.contains($0, p) }
    }

    /// Type på norsk («delstat», «fylke», «provins» …).
    var kindName: String {
        switch kind.lowercased() {
        case "state": "delstat"
        case "county": country == "NO" ? "fylke" : "county"
        case "province": "provins"
        case "region": "region"
        case "department": "departement"
        case "canton": "kanton"
        case "territory": "territorium"
        case "federal district": "føderalt distrikt"
        case "": "land"
        default: kind.lowercased()
        }
    }
}

enum World {
    static let countries: [GeoArea] = load("world-countries", isCountry: true)
    static let regions: [GeoArea] = load("world-regions", isCountry: false)

    private struct Raw: Decodable {
        let code: String?
        let name: String?
        let kind: String?
        let country: String?
        let box: [Double]
        let rings: [[Double]]
    }

    private static func load(_ file: String, isCountry: Bool) -> [GeoArea] {
        guard let url = Bundle.module.url(forResource: file, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        return raw.compactMap { r in
            // Noen få regioner i Natural Earth mangler kode eller navn; de hoppes over.
            guard let code = r.code, let name = r.name, !code.isEmpty, !name.isEmpty else { return nil }
            let rings = r.rings.map { flat in stride(from: 0, to: flat.count - 1, by: 2).map { GeoPoint(lat: flat[$0 + 1], lon: flat[$0]) } }
            return GeoArea(code: code, name: name, kind: isCountry ? "" : (r.kind ?? ""),
                           country: isCountry ? code : (r.country ?? ""),
                           minLat: r.box[1], minLon: r.box[0], maxLat: r.box[3], maxLon: r.box[2], rings: rings)
        }
    }

    /// Regionen et punkt ligger i. Ligger punktet like utenfor (forenklet kystlinje), brukes nærmeste
    /// region innen ca. 30 km.
    static func region(at p: GeoPoint) -> GeoArea? { find(p, in: regions) }
    static func country(at p: GeoPoint) -> GeoArea? { find(p, in: countries) }

    private static func find(_ p: GeoPoint, in list: [GeoArea]) -> GeoArea? {
        if let inside = list.first(where: { $0.contains(p) }) { return inside }
        let margin = 0.3
        let squeeze = cos(p.lat * .pi / 180)
        var best: (GeoArea, Double)?
        for area in list where p.lat >= area.minLat - margin && p.lat <= area.maxLat + margin
            && p.lon >= area.minLon - margin && p.lon <= area.maxLon + margin {
            for ring in area.rings {
                for q in ring {
                    let d = hypot(q.lat - p.lat, (q.lon - p.lon) * squeeze)
                    if d < (best?.1 ?? margin) { best = (area, d) }
                }
            }
        }
        return best?.0
    }

    /// Alle filterkoder et punkt hører til: regionene og landene det ligger i, og dem som har grense
    /// innen `km` (grensene er forenklet, så punkter ved en grense kan havne på feil side).
    /// Region = «US-TX», land = «land:US».
    static func filterCodes(at p: GeoPoint, km: Double = 5) -> Set<String> {
        var codes = Set<String>()
        for area in near(p, km: km, in: regions) { codes.insert(area.code); codes.insert("land:\(area.country)") }
        for area in near(p, km: km, in: countries) { codes.insert("land:\(area.code)") }
        if codes.isEmpty, let r = region(at: p) { codes.insert(r.code); codes.insert("land:\(r.country)") }
        if !codes.contains(where: { $0.hasPrefix("land:") }), let c = country(at: p) { codes.insert("land:\(c.code)") }
        return codes
    }

    /// Områdene punktet ligger i, eller har grense innen `km` fra.
    private static func near(_ p: GeoPoint, km: Double, in list: [GeoArea]) -> [GeoArea] {
        let dLat = km / 111
        let dLon = km / (111 * max(cos(p.lat * .pi / 180), 0.1))
        return list.filter { area in
            guard p.lat >= area.minLat - dLat, p.lat <= area.maxLat + dLat,
                  p.lon >= area.minLon - dLon, p.lon <= area.maxLon + dLon else { return false }
            return area.contains(p) || area.rings.contains { ring in distanceToRingKm(p, ring) <= km }
        }
    }

    /// Korteste avstand (km) fra punktet til kanten av en ring (flat tilnærming, fint for korte avstander).
    private static func distanceToRingKm(_ p: GeoPoint, _ ring: [GeoPoint]) -> Double {
        let kx = 111 * cos(p.lat * .pi / 180), ky = 111.0
        var best = Double.infinity
        var j = ring.count - 1
        for i in ring.indices {
            let ax = (ring[j].lon - p.lon) * kx, ay = (ring[j].lat - p.lat) * ky
            let bx = (ring[i].lon - p.lon) * kx, by = (ring[i].lat - p.lat) * ky
            let dx = bx - ax, dy = by - ay
            let len = dx * dx + dy * dy
            let t = len > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len)) : 0
            let cx = ax + t * dx, cy = ay + t * dy
            best = min(best, (cx * cx + cy * cy).squareRoot())
            j = i
        }
        return best
    }

    static func region(code: String) -> GeoArea? { regions.first { $0.code == code } }
    static func country(code: String) -> GeoArea? { countries.first { $0.code == code } }

    /// Landsnavn på norsk («USA», «Norge»), ellers navnet fra Natural Earth.
    static func countryName(_ code: String) -> String {
        Locale(identifier: "nb_NO").localizedString(forRegionCode: code) ?? country(code: code)?.name ?? code
    }

    // MARK: Filter: en region eller et helt land

    /// Et filter er en regionkode («US-NM») eller et helt land («land:US»).
    static func filterArea(_ filter: String?) -> GeoArea? {
        guard let filter else { return nil }
        if filter.hasPrefix("land:") { return country(code: String(filter.dropFirst(5))) }
        return region(code: filter)
    }

    /// «New Mexico, USA» eller «USA (hele landet)».
    static func filterName(_ filter: String?) -> String? {
        guard let filter else { return nil }
        if filter.hasPrefix("land:") { return "\(countryName(String(filter.dropFirst(5)))) (hele landet)" }
        guard let r = region(code: filter) else { return nil }
        return "\(r.name), \(countryName(r.country))"
    }
}
