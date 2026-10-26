import CoreLocation
import Foundation

/// Områder: et overordnet navn over stedene (Blue Ridge Mountains over Sylva). Et område er bare bildene
/// du har gitt det; det foreslås for bilder i nærheten (innen samme radius som i fokusmodus) og for
/// bildene rundt på rullen.
extension AppModel {
    /// Alle områder i bruk, med bildene som har dem.
    var areaNames: [(name: String, ids: [String])] {
        var groups: [String: [String]] = [:]
        for photo in photos {
            if let area = info(photo.id).area, !area.isEmpty { groups[area, default: []].append(photo.id) }
        }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, groups[$0]!) }
    }

    /// Områdeforslag for et bilde: bildene rundt på rullen, områder brukt i nærheten (mest brukt først),
    /// sist brukt, så alle andre. Filtreres på det du har skrevet.
    func areaOptions(for id: String, typed: String) -> [FocusSession.Option] {
        var options: [FocusSession.Option] = []
        func add(_ name: String?, _ detail: String) {
            guard let name, !name.isEmpty,
                  typed.isEmpty || name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  !options.contains(where: { $0.title == name }) else { return }
            options.append(.init(title: name, detail: detail))
        }
        let n = rollNeighbors(of: id)
        if let b = n.before { add(info(b.id).area, b.steps == 1 ? "bildet før på rullen" : "\(b.steps) bilder før på rullen") }
        if let a = n.after { add(info(a.id).area, a.steps == 1 ? "bildet etter på rullen" : "\(a.steps) bilder etter på rullen") }
        let areas = areaNames
        // Områder du har brukt i nærheten av bildets sted, bildene rundt eller de mest like iPhone-bildene.
        let anchors = areaAnchors(for: id)
        if !anchors.isEmpty {
            let nearby = areas.map { area -> (String, Int) in
                let count = area.ids.filter { other in
                    guard let q = info(other).place, let a = q.latitude, let b = q.longitude else { return false }
                    let point = GeoPoint(lat: a, lon: b)
                    return anchors.contains { distanceKm($0, point) < Self.focusRadiusKm }
                }.count
                return (area.name, count)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            for (name, count) in nearby { add(name, count == 1 ? "1 bilde i nærheten" : "\(count) bilder i nærheten") }
        }
        // Steder i nærheten av bildets kartpunkt (nasjonalmonument, verneområde …).
        if let p = info(id).place, let lat = p.latitude, let lon = p.longitude {
            for option in nearbyPlaces(GeoPoint(lat: lat, lon: lon)) where option.title != p.name {
                add(option.title, option.detail)
            }
        }
        // Fra kartet: regioner punktene ligger i, park/skog fra Apple.
        for anchor in anchors {
            for hint in areaHints[Self.hintKey(anchor)] ?? [] { add(hint.title, hint.detail) }
        }
        add(project.lastArea, "sist brukt")
        for area in areas.sorted(by: { $0.ids.count > $1.ids.count }) {
            add(area.name, area.ids.count == 1 ? "brukt på 1 bilde" : "brukt på \(area.ids.count) bilder")
        }
        if !typed.isEmpty {
            // Når du skriver: også alle landskapsregioner og delstater som passer, så søketreff fra Apple
            // (nasjonalparker, skoger o.l.).
            func starts(_ name: String) -> Bool { name.lowercased().hasPrefix(typed.lowercased()) }
            for region in USRegion.all.sorted(by: { starts($0.name) && !starts($1.name) }) { add(region.name, region.kindName) }
            for state in USState.all.sorted(by: { starts($0.name) && !starts($1.name) }) { add(state.name, "delstat") }
            for result in areaSearch.results where !options.contains(where: { $0.title == result.title }) {
                options.append(.init(title: result.title, detail: result.subtitle, searchSubtitle: result.subtitle))
            }
            // De som begynner med det du har skrevet, først.
            let (first, rest) = (options.filter { starts($0.title) }, options.filter { !starts($0.title) })
            options = first + rest
        }
        return options
    }

    // MARK: Forslag fra kartet

    nonisolated static func hintKey(_ p: GeoPoint) -> String { String(format: "%.2f,%.2f", p.lat, p.lon) }

    /// Punktene områdeforslagene bygger på: bildets eget sted, så bildene rundt på rullen, så de tre
    /// mest like iPhone-bildene (så du får forslag før du har valgt sted).
    func areaAnchors(for id: String) -> [GeoPoint] {
        var points: [GeoPoint] = []
        func add(_ place: Place?) {
            guard let lat = place?.latitude, let lon = place?.longitude else { return }
            let p = GeoPoint(lat: lat, lon: lon)
            if !points.contains(where: { distanceKm($0, p) < 2 }) { points.append(p) }
        }
        add(info(id).place)
        let n = rollNeighbors(of: id)
        add(n.before.flatMap { info($0.id).place })
        add(n.after.flatMap { info($0.id).place })
        if let similarity, similarity.suggestionsFor == id {
            for s in similarity.suggestions.prefix(3) {
                if let c = s.asset.location?.coordinate { add(Place(name: "", latitude: c.latitude, longitude: c.longitude)) }
            }
        }
        return points
    }

    /// Henter områdeforslag fra kartet for punktene til et bilde (én gang per punkt):
    /// - nasjonalpark fra Apples stedsoppslag (bare koordinatene sendes), på engelsk
    /// - geografiske regioner punktet ligger i (Natural Earth, lokalt), mest presise først
    /// - nasjonalskog o.l. fra Apple, så delstaten
    func loadAreaHints(for id: String) async {
        for point in areaAnchors(for: id) { await loadAreaHints(at: point) }
    }

    private func loadAreaHints(at point: GeoPoint) async {
        let key = Self.hintKey(point)
        guard areaHints[key] == nil else { return }
        areaHints[key] = []  // ikke slå opp samme punkt to ganger samtidig
        var hints: [FocusSession.Option] = []
        func add(_ name: String?, _ detail: String) {
            guard let name, !name.isEmpty, !hints.contains(where: { $0.title == name }) else { return }
            hints.append(.init(title: name, detail: detail))
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: point.lat, longitude: point.lon),
                                                                         preferredLocale: Locale(identifier: "en_US")).first
        let aois = placemark?.areasOfInterest ?? []
        for aoi in aois where aoi.contains("National Park") { add(aoi, "nasjonalpark, fra kartet") }
        for region in USRegion.containing(point) { add(region.name, "\(region.kindName), fra kartet") }
        for aoi in aois where aoi.contains("Forest") || aoi.contains("Monument") || aoi.contains("State Park")
            || aoi.contains("Recreation") || aoi.contains("Parkway") {
            add(aoi, "fra kartet")
        }
        areaHints[key] = hints
    }

    /// Gir alle bilder i området et nytt navn (samme navn som et annet område slår dem sammen).
    func renameArea(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard name != old else { return }
        for photo in photos where info(photo.id).area == old {
            update(photo.id) { $0.area = name.isEmpty ? nil : name }
        }
        if project.lastArea == old { project.lastArea = name.isEmpty ? nil : name }
    }
}
