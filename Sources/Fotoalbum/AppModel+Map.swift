import Foundation

/// Hvilken stat et punkt ligger i, husket så vi ikke regner det ut igjen og igjen.
@MainActor private var stateCache: [GeoPoint: String] = [:]

/// Kartet i boka: hvilke sider som får kart, og hva kartet på en side viser.
extension AppModel {
    func stateCode(_ p: GeoPoint) -> String? {
        if let hit = stateCache[p] { return hit.isEmpty ? nil : hit }
        let code = USState.at(p)?.code ?? ""
        stateCache[p] = code
        return code.isEmpty ? nil : code
    }

    private func coordinate(of photo: String) -> GeoPoint? {
        guard let place = info(photo).place, let lat = place.latitude, let lon = place.longitude else { return nil }
        return GeoPoint(lat: lat, lon: lon)
    }

    /// Staten siden er fra: staten til første bilde med kartpunkt.
    func state(of page: BookPage) -> String? {
        page.photos.lazy.compactMap { self.coordinate(of: $0) }.compactMap { self.stateCode($0) }.first
    }

    /// Ny stat på denne siden? (Første side med en stat regnes også som ny.)
    func isNewState(_ index: Int) -> Bool {
        let pages = book.pages
        guard pages.indices.contains(index), let mine = state(of: pages[index]) else { return false }
        for i in stride(from: index - 1, through: 0, by: -1) {
            if let earlier = state(of: pages[i]) { return earlier != mine }
        }
        return true
    }

    func showsMap(_ index: Int) -> Bool {
        let pages = book.pages
        guard pages.indices.contains(index) else { return false }
        switch pages[index].map {
        case .show: return true
        case .hide: return false
        case nil: return isNewState(index)
        }
    }

    func setMap(_ choice: MapChoice?, for pageID: UUID) {
        guard var b = project.book, let i = b.pages.firstIndex(where: { $0.id == pageID }) else { return }
        b.pages[i].map = choice
        project.book = b
        scheduleSave()
    }

    /// Kartet for siden: ruten fram til bildene på siden ble tatt, og hvor vi er.
    func mapData(_ index: Int) -> MapData? {
        let pages = book.pages
        guard pages.indices.contains(index) else { return nil }
        let photos = pages[index].photos
        let here = photos.compactMap(coordinate(of:)).last

        // Hvor langt ruten har kommet: siste klokkeslett på siden, ellers slutten av dagen.
        var cutoff = photos.compactMap { info($0).time }.max()
        if cutoff == nil, let day = photos.compactMap({ info($0).day }).max() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = here.map { PhoneLibrary.approximateZone(.init(latitude: $0.lat, longitude: $0.lon)) }
                ?? TimeZone(identifier: "America/Denver")!
            cutoff = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day + 1))
        }
        guard let cutoff else { return nil }

        // Bare fastlands-USA (grovt), så bilder hjemmefra ikke drar ruten ut av kartet.
        let route = (project.route ?? []).filter { $0.time <= cutoff }
            .map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }
            .filter { (24...50).contains($0.lat) && (-125...(-66)).contains($0.lon) }
        let position = here ?? route.last
        var visited = Set(route.compactMap(stateCode))
        if let position, let code = stateCode(position) { visited.insert(code) }
        return MapData(route: route, here: here, visited: visited, current: position.flatMap(stateCode))
    }
}
