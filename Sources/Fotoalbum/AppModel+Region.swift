import Foundation
import Photos

/// Region (stat, fylke, provins) eller helt land som filter i fokusvisningen: like bilder, iPhone-bildene
/// til høyre, kartet, stedsforslag og datoforslag holdes innenfor.
extension AppModel {
    /// Bildets egen region som filterkode («US-NM», eller «land:US» hvis bare landet er kjent).
    func photoFilter(_ i: PhotoInfo) -> String? {
        if let r = i.regionCode { return r }
        if let c = i.countryCode { return "land:\(c)" }
        return nil
    }

    /// Filteret sidene skal vise: i Region-steget det markerte forslaget, ellers bildets region,
    /// ellers den du valgte sist (står til neste bilde).
    var focusPreviewRegion: String? {
        if focus.step == .region {
            let options = focusOptions
            if let h = focus.highlighted, options.indices.contains(h) { return options[h].code }
        }
        return focus.current.flatMap { photoFilter(info($0)) } ?? focus.browseRegion
    }

    var focusFilterShape: AreaShape? { World.filterArea(focusPreviewRegion).map { .area($0) } }

    /// Velg region fra velgeren til høyre: blir filteret (og bildets region hvis det ikke har sted).
    func focusPickRegion(_ code: String?) {
        focus.browseRegion = code
        guard let id = focus.current, info(id).place?.latitude == nil else { return }
        update(id) {
            if let code, code.hasPrefix("land:") { $0.regionCode = nil; $0.countryCode = String(code.dropFirst(5)) }
            else { $0.regionCode = code; $0.countryCode = code.flatMap { World.region(code: $0)?.country } }
        }
        placeSearch.prefer(focusFilterShape?.region)
    }

    /// Landene turen har vært i (fra ruten), så regioner der foreslås først når du skriver.
    var visitedCountries: Set<String> {
        if let cached = visitedCountryCache, cached.count == project.route?.count ?? 0 { return cached.countries }
        var countries = Set<String>()
        var last: GeoPoint?
        for p in project.route ?? [] {
            let point = GeoPoint(lat: p.latitude, lon: p.longitude)
            if let last, distanceKm(last, point) < 50 { continue }
            last = point
            if let c = World.country(at: point)?.code { countries.insert(c) }
        }
        visitedCountryCache = (project.route?.count ?? 0, countries)
        return countries
    }

    /// Regionforslag. Tomt felt: forrige bildes region, bildene rundt på rullen, de like iPhone-bildene,
    /// og hele landet for disse. Når du skriver: regioner og land som passer, først i land du har vært i.
    func regionOptions(for id: String, typed: String) -> [FocusSession.Option] {
        var options: [FocusSession.Option] = []
        func add(_ code: String?, _ detail: String) {
            guard let code, let name = World.filterName(code), !options.contains(where: { $0.code == code }) else { return }
            options.append(.init(title: name, detail: detail, code: code))
        }
        if typed.isEmpty {
            add(focus.browseRegion, "samme som forrige bilde")
            let n = rollNeighbors(of: id)
            if let b = n.before { add(photoFilter(info(b.id)), b.steps == 1 ? "bildet før på rullen" : "\(b.steps) bilder før på rullen") }
            if let a = n.after { add(photoFilter(info(a.id)), a.steps == 1 ? "bildet etter på rullen" : "\(a.steps) bilder etter på rullen") }
            if let similarity, similarity.suggestionsFor == id {
                for s in similarity.suggestions.prefix(3) {
                    if let c = s.asset.location?.coordinate { add(World.region(at: GeoPoint(lat: c.latitude, lon: c.longitude))?.code, "like iPhone-bilder") }
                }
            }
            // Hele landet for regionene over.
            for country in Set(options.compactMap { $0.code.flatMap { World.region(code: $0)?.country } }).sorted() {
                add("land:\(country)", "land")
            }
            return options
        }
        let query = typed.lowercased()
        let visited = visitedCountries
        func score(_ name: String, _ country: String) -> Int {
            (name.lowercased().hasPrefix(query) ? 0 : 2) + (visited.contains(country) ? 0 : 1)
        }
        let regions = World.regions.filter { $0.name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { score($0.name, $0.country) < score($1.name, $1.country) }
        let countries = World.countries.filter {
            World.countryName($0.code).range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        for c in countries where visited.contains(c.code) { add("land:\(c.code)", "land") }
        for r in regions.prefix(12) { add(r.code, r.kindName) }
        for c in countries where !visited.contains(c.code) { add("land:\(c.code)", "land") }
        return options
    }
}

// MARK: Region per kartpunkt (for filtrering av iPhone-bilder)

extension AppModel {
    /// Nøkkel for et kartpunkt (ca. 1 km), så bilder tatt nær hverandre deler oppslag.
    nonisolated static func regionKey(_ p: GeoPoint) -> String { String(format: "%.2f,%.2f", p.lat, p.lon) }

    /// Filterkodene for et punkt (regioner og land det ligger i eller innen 5 km fra). Husket per punkt.
    func filterCodes(_ p: GeoPoint) -> Set<String> {
        let key = Self.regionKey(p)
        if let hit = regionCache[key] { return hit }
        let codes = World.filterCodes(at: p)
        regionCache[key] = codes
        return codes
    }

    /// Ligger punktet i filteret (region «US-WA» eller helt land «land:US»)? Uten filter: ja.
    func filterMatches(_ p: GeoPoint, _ filter: String?) -> Bool {
        guard let filter else { return true }
        return filterCodes(p).contains(filter)
    }

    /// Hører iPhone-bildet til filteret? Bilder uten GPS bruker posisjonen til nærmeste bilde i tid
    /// (innen 3 timer, se precomputeRegions); finnes ingen, er de ikke med når det filtreres.
    func assetMatches(_ asset: PHAsset, _ filter: String?) -> Bool {
        guard let filter else { return true }
        if let c = asset.location?.coordinate { return filterMatches(GeoPoint(lat: c.latitude, lon: c.longitude), filter) }
        guard let p = borrowedPoints[asset.localIdentifier] else { return false }
        return filterMatches(p, filter)
    }

    /// I bakgrunnen: filterkodene for alle iPhone-bildene, og lånt posisjon for bilder uten GPS.
    func precomputeRegions(phone: PhoneLibrary) {
        let assets = phone.days.flatMap(\.assets)
        var located: [(time: Date, point: GeoPoint)] = []
        var unlocated: [(id: String, time: Date)] = []
        for asset in assets {
            guard let time = asset.creationDate else { continue }
            if let c = asset.location?.coordinate { located.append((time, GeoPoint(lat: c.latitude, lon: c.longitude))) }
            else { unlocated.append((asset.localIdentifier, time)) }
        }
        located.sort { $0.time < $1.time }
        // Bilder uten GPS: nærmeste bilde med GPS i tid, innen 3 timer.
        var borrowed: [String: GeoPoint] = [:]
        for (id, time) in unlocated {
            var lo = 0, hi = located.count
            while lo < hi { let mid = (lo + hi) / 2; if located[mid].time < time { lo = mid + 1 } else { hi = mid } }
            let candidates = [lo - 1, lo].filter { located.indices.contains($0) }
            if let best = candidates.min(by: { abs(located[$0].time.timeIntervalSince(time)) < abs(located[$1].time.timeIntervalSince(time)) }),
               abs(located[best].time.timeIntervalSince(time)) <= 3 * 3600 {
                borrowed[id] = located[best].point
            }
        }
        borrowedPoints = borrowed
        let points = located.map(\.point) + Array(borrowed.values)
        let missing = Array(Set(points.map(Self.regionKey)).subtracting(regionCache.keys))
        guard !missing.isEmpty else { regionCacheVersion += 1; return }
        let byKey = Dictionary(points.map { (Self.regionKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        Task {
            let found = await Task.detached(priority: .utility) {
                missing.reduce(into: [String: Set<String>]()) { result, key in
                    if let p = byKey[key] { result[key] = World.filterCodes(at: p) }
                }
            }.value
            regionCache.merge(found) { a, _ in a }
            regionCacheVersion += 1
        }
    }
}
