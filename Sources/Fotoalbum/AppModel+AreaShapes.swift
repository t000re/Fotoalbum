import MapKit
import Photos

/// Formen til et område, så kart, iPhone-bilder, like bilder og stedsforslag kan holdes innenfor det.
enum AreaShape: Hashable {
    /// Omriss (landskapsregioner og delstater).
    case polygons([[GeoPoint]])
    /// Sirkel (nasjonalparker, områder du har laget selv).
    case circle(GeoPoint, km: Double)
    /// Land eller region (stat, fylke …) fra World.
    case area(GeoArea)

    /// Omrisset som skal tegnes på kartet (tomt for sirkel).
    var rings: [[GeoPoint]] {
        switch self {
        case .polygons(let rings): rings
        case .area(let a): a.rings
        case .circle: []
        }
    }

    func contains(_ p: GeoPoint) -> Bool {
        switch self {
        case .area(let a): a.contains(p)
        case .polygons(let rings): rings.contains { USState.contains($0, p) }
        case .circle(let center, let km): distanceKm(center, p) <= km
        }
    }

    /// Kartutsnitt som viser hele området, med litt luft.
    var region: MKCoordinateRegion {
        switch self {
        case .area(let a):
            return MKCoordinateRegion(center: .init(latitude: (a.minLat + a.maxLat) / 2, longitude: (a.minLon + a.maxLon) / 2),
                                      span: .init(latitudeDelta: (a.maxLat - a.minLat) * 1.2 + 0.2,
                                                  longitudeDelta: min(360, (a.maxLon - a.minLon) * 1.2 + 0.2)))
        case .circle(let c, let km):
            let lat = 2 * km / 111 * 1.3
            return MKCoordinateRegion(center: .init(latitude: c.lat, longitude: c.lon),
                                      span: .init(latitudeDelta: lat, longitudeDelta: lat / max(cos(c.lat * .pi / 180), 0.2)))
        case .polygons(let rings):
            let points = rings.flatMap { $0 }
            let lats = points.map(\.lat), lons = points.map(\.lon)
            let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0, minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
            return MKCoordinateRegion(center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                      span: .init(latitudeDelta: (maxLat - minLat) * 1.2 + 0.2, longitudeDelta: (maxLon - minLon) * 1.2 + 0.2))
        }
    }
}

extension AppModel {
    /// Formen til et område, hvis den er funnet (se resolveAreaShape).
    func areaShape(_ name: String?) -> AreaShape? {
        guard let name, !name.isEmpty else { return nil }
        return areaShapes[name]
    }

    /// Området til et bilde som form, til filtrering.
    func areaShape(for id: String) -> AreaShape? { areaShape(info(id).area) }

    /// Finner formen til et område (én gang per navn):
    /// landskapsregion eller delstat → omrisset; område du har brukt → sirkel rundt bildene (minst 100 km);
    /// ellers Apples stedssøk på navnet → 100 km rundt punktet.
    func resolveAreaShape(_ name: String?) async {
        guard let name, !name.isEmpty, areaShapes[name] == nil else { return }
        if let region = USRegion.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            areaShapes[name] = .polygons(region.rings); return
        }
        if let state = USState.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.code == name }) {
            areaShapes[name] = .polygons(state.rings); return
        }
        let points = photos.compactMap { photo -> GeoPoint? in
            let i = info(photo.id)
            guard i.area == name, let lat = i.place?.latitude, let lon = i.place?.longitude else { return nil }
            return GeoPoint(lat: lat, lon: lon)
        }
        if !points.isEmpty {
            let center = GeoPoint(lat: points.map(\.lat).reduce(0, +) / Double(points.count),
                                  lon: points.map(\.lon).reduce(0, +) / Double(points.count))
            let spread = points.map { distanceKm(center, $0) }.max() ?? 0
            areaShapes[name] = .circle(center, km: max(Self.focusRadiusKm, spread + 30)); return
        }
        if let point = await Self.lookUpCoordinates(name) {
            areaShapes[name] = .circle(point, km: Self.focusRadiusKm)
        }
    }

    /// Filter for iPhone-bilder: bare de med GPS innenfor bildets område (nil = ingen filter).
    func phoneFilter(for id: String) -> ((PHAsset) -> Bool)? {
        guard let shape = areaShape(for: id) else { return nil }
        return { asset in
            guard let c = asset.location?.coordinate else { return false }
            return shape.contains(GeoPoint(lat: c.latitude, lon: c.longitude))
        }
    }
}

extension AppModel {
    /// iPhone-bildene innenfor bildets område (ID-er), til «Like bilder». nil = intet område.
    func allowedPhoneIDs(for id: String?) -> Set<String>? {
        guard let id, let filter = phoneFilter(for: id), let phone else { return nil }
        return Set(phone.days.flatMap(\.assets).filter(filter).map(\.localIdentifier))
    }
}

extension AppModel {
    /// iPhone-bildene innenfor området fokusmodus filtrerer på (bildets eget eller det valgte til høyre).
    var focusAllowedPhoneIDs: Set<String>? {
        guard let filter = focusPreviewRegion, let phone else { return nil }
        return Set(phone.days.flatMap(\.assets).filter { assetMatches($0, filter) }.map(\.localIdentifier))
    }
}
