import CoreLocation
import MapKit
import Photos
import SwiftUI

/// iPhone-bildene fra Bilder-appen, gruppert per dag. Vi leser bare: ingenting endres i Bilder.
/// Bildene vises bare her i appen og sendes ingen steder.
@MainActor @Observable
final class PhoneLibrary {
    enum Access { case unknown, denied, granted }

    /// Én dag med iPhone-bilder.
    struct DayGroup: Identifiable {
        let day: Day
        let assets: [PHAsset]
        var id: Day { day }
    }

    /// Mange bilder tatt nær hverandre, vist som én prikk på kartet.
    struct MapPoint: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let count: Int
    }

    private(set) var access: Access = .unknown
    private(set) var days: [DayGroup] = []
    private(set) var count = 0
    private(set) var mapPoints: [MapPoint] = []
    /// Ruten: alle iPhone-bilder med GPS i perioden, i tidsrekkefølge, uten punkter tettere enn ca. 2 km.
    private(set) var route: [RoutePoint] = []
    /// Alle iPhone-bilder med GPS i perioden, i tidsrekkefølge, med dagen de står under (for stedslista).
    private(set) var located: [(point: GeoPoint, day: Day)] = []

    /// Området vi viser bilder fra (fra søk eller kartet). nil = alle bilder.
    var area: MKCoordinateRegion?
    /// Navnet på området, f.eks. «Montana, MT».
    var areaName: String?

    /// Dagene med bare bildene innenfor området (bilder uten GPS faller bort når området er satt).
    var visibleDays: [DayGroup] {
        guard let area else { return days }
        return days.compactMap { group in
            let assets = group.assets.filter { $0.location.map { area.contains($0.coordinate) } ?? false }
            return assets.isEmpty ? nil : DayGroup(day: group.day, assets: assets)
        }
    }

    /// Søker etter et sted («Montana», «Grand Canyon») og viser bildene derfra.
    /// Små treff (en landsby) utvides til minst ca. 30 km, så bilder like ved kommer med.
    func search(_ text: String) async -> Bool {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        // Foretrekk treff i USA.
        request.region = MKCoordinateRegion(center: .init(latitude: 39, longitude: -98),
                                            span: .init(latitudeDelta: 30, longitudeDelta: 60))
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return false }
        var region = response.boundingRegion
        region.span.latitudeDelta = max(region.span.latitudeDelta, 0.3)
        region.span.longitudeDelta = max(region.span.longitudeDelta, 0.4)
        area = region
        areaName = [item.name, item.placemark.administrativeArea].compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ", ")
        return true
    }

    func clearArea() { area = nil; areaName = nil }
    /// Hvilken dag hvert iPhone-bilde står under.
    private var dayOf: [String: Day] = [:]
    let imageManager = PHCachingImageManager()

    init() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: access = .granted
        case .denied, .restricted: access = .denied
        default: access = .unknown
        }
    }

    /// Spør om tilgang (macOS viser sin egen dialog første gang).
    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = (status == .authorized || status == .limited) ? .granted : .denied
    }

    /// Henter bildene fra perioden, sortert på tid og gruppert per dag på stedet de ble tatt.
    func load(from start: Day, to end: Day) {
        guard access == .granted else { return }
        // En dag ekstra i hver ende, fordi tidssonen i USA flytter dagsgrensen i forhold til Norge.
        let from = start.date.addingTimeInterval(-36 * 3600)
        let to = end.date.addingTimeInterval(36 * 3600)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
                                        PHAssetMediaType.image.rawValue, from as NSDate, to as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)

        var groups: [Day: [PHAsset]] = [:]
        var zone = TimeZone.current
        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            // Bilder uten GPS får tidssonen til forrige bilde med GPS.
            if let location = asset.location { zone = Self.approximateZone(location.coordinate) }
            let day = Day(date, timeZone: zone)
            guard day >= start, day <= end else { return }
            groups[day, default: []].append(asset)
        }
        days = groups.keys.sorted().map { DayGroup(day: $0, assets: groups[$0]!) }
        count = days.reduce(0) { $0 + $1.assets.count }
        dayOf = [:]
        for group in days { for asset in group.assets { dayOf[asset.localIdentifier] = group.day } }

        route = []
        located = []
        for group in days {
            for asset in group.assets {
                if let c = asset.location?.coordinate {
                    located.append((GeoPoint(lat: c.latitude, lon: c.longitude), group.day))
                }
            }
        }
        var last: CLLocation?
        for group in days {
            for asset in group.assets {
                guard let location = asset.location, let time = asset.creationDate else { continue }
                if let last, location.distance(from: last) < 2000 { continue }
                last = location
                route.append(RoutePoint(time: time, latitude: location.coordinate.latitude,
                                        longitude: location.coordinate.longitude))
            }
        }

        // Prikker til kartet: bildene samlet i ruter på ca. 5 km.
        var cells: [String: (lat: Double, lon: Double, n: Int)] = [:]
        for group in days {
            for asset in group.assets {
                guard let c = asset.location?.coordinate else { continue }
                let key = "\(Int((c.latitude / 0.05).rounded())),\(Int((c.longitude / 0.05).rounded()))"
                let old = cells[key] ?? (0, 0, 0)
                cells[key] = (old.lat + c.latitude, old.lon + c.longitude, old.n + 1)
            }
        }
        mapPoints = cells.map { key, v in
            MapPoint(id: key, coordinate: .init(latitude: v.lat / Double(v.n), longitude: v.lon / Double(v.n)), count: v.n)
        }
    }

    /// Omtrentlig tidssone ut fra lengdegraden (1 time per 15°). Godt nok til å gruppere i dager;
    /// når du kopierer, brukes den nøyaktige tidssonen fra stedsoppslaget.
    nonisolated static func approximateZone(_ c: CLLocationCoordinate2D) -> TimeZone {
        TimeZone(secondsFromGMT: Int((c.longitude / 15).rounded()) * 3600) ?? .current
    }

    /// Tidspunktene til iPhone-bildene med disse ID-ene (for analoge bilder koblet før vi lagret tid).
    func creationDates(for ids: [String]) -> [String: Date] {
        guard access == .granted, !ids.isEmpty else { return [:] }
        var result: [String: Date] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            if let date = asset.creationDate { result[asset.localIdentifier] = date }
        }
        return result
    }

    // MARK: Stedsnavn

    private let geocoder = CLGeocoder()
    private var placeCache: [String: CLPlacemark] = [:]

    /// Slår opp stedet for koordinatene (Apples kartdatabase; bare koordinatene sendes, ikke bildet).
    private func placemark(for location: CLLocation) async -> CLPlacemark? {
        let key = String(format: "%.3f,%.3f", location.coordinate.latitude, location.coordinate.longitude)
        if let hit = placeCache[key] { return hit }
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        placeCache[key] = placemark
        return placemark
    }

    /// Mulige navn, fra mest presist til minst: severdighet («Half Dome»), by/park
    /// («Yosemite National Park»), by med delstat, delstat.
    func nameAlternatives(latitude: Double, longitude: Double) async -> [String] {
        guard let p = await placemark(for: CLLocation(latitude: latitude, longitude: longitude)) else { return [] }
        var names = p.areasOfInterest ?? []
        if let city = p.locality {
            names.append(city)
            if let state = p.administrativeArea { names.append("\(city), \(state)") }
        }
        if let state = p.administrativeArea { names.append(state) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Bredere navn til stedslista: by eller park, ellers severdighet, ellers delstat.
    func areaName(for location: CLLocation) async -> String? {
        guard let p = await placemark(for: location) else { return nil }
        let name = p.locality ?? p.areasOfInterest?.first ?? p.administrativeArea ?? p.name ?? ""
        return name.isEmpty ? nil : name
    }

    /// Standardnavnet: severdighet/park hvis det finnes, ellers by, ellers delstat.
    func placeName(for location: CLLocation) async -> (name: String, zone: TimeZone?)? {
        guard let placemark = await placemark(for: location) else { return nil }
        let name = placemark.areasOfInterest?.first ?? placemark.locality
            ?? placemark.administrativeArea ?? placemark.name ?? ""
        return name.isEmpty ? nil : (name, placemark.timeZone)
    }

    /// Dato og sted fra et iPhone-bilde, klare til å kopieres.
    func dayAndPlace(of asset: PHAsset) async -> (day: Day?, place: Place?, zone: TimeZone?) {
        guard let date = asset.creationDate else { return (nil, nil, nil) }
        guard let location = asset.location else {
            // Uten GPS: samme dag som bildet står under i panelet.
            return (dayOf[asset.localIdentifier] ?? Day(date), nil, nil)
        }
        let lookup = await placeName(for: location)
        let zone = lookup?.zone ?? Self.approximateZone(location.coordinate)
        let place = Place(name: lookup?.name ?? "", latitude: location.coordinate.latitude,
                          longitude: location.coordinate.longitude)
        return (Day(date, timeZone: zone), place.name.isEmpty ? nil : place, lookup?.zone)
    }
}

/// Miniatyr av et iPhone-bilde i en rute med fast form (`aspect` = bredde/høyde). Bildet fyller ruta
/// og beskjæres inni den, så det aldri blir større enn ruta. Henter fra iCloud om bildet ikke ligger lokalt.
struct PhoneThumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    var aspect: CGFloat = 1
    @State private var image: NSImage?

    var body: some View {
        // Ruta får sin størrelse fra bredden den får og formen; bildet legges oppå og klippes.
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .background(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            manager.requestImage(for: asset, targetSize: CGSize(width: 280, height: 280),
                                 contentMode: .aspectFill, options: options) { result, _ in
                if let result { image = result }
            }
        }
    }
}

extension MKCoordinateRegion {
    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude - center.latitude) <= span.latitudeDelta / 2
            && abs(c.longitude - center.longitude) <= span.longitudeDelta / 2
    }
}
